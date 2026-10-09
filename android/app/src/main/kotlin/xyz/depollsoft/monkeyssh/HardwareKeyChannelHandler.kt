package xyz.depollsoft.monkeyssh

import android.app.Activity
import android.app.Application
import android.app.KeyguardManager
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyInfo
import android.security.keystore.KeyPermanentlyInvalidatedException
import android.security.keystore.KeyProperties
import android.security.keystore.StrongBoxUnavailableException
import android.util.Log
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.lang.ref.WeakReference
import java.math.BigInteger
import java.security.InvalidAlgorithmParameterException
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.PrivateKey
import java.security.Signature
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Non-exportable P-256 SSH keys in Android Keystore, in StrongBox when the
 * device has one and in the TEE otherwise.
 *
 * Only the alias and public key leave this class. It never logs key material,
 * signatures, aliases, or the data being signed.
 */
object HardwareKeyChannelHandler {
    private const val CHANNEL = "xyz.depollsoft.monkeyssh/hardware_keys"
    private const val TAG = "HardwareKeyChannel"
    private const val KEYSTORE = "AndroidKeyStore"
    private const val PROBE_ALIAS = "xyz.depollsoft.monkeyssh.sshkey.capability-probe"
    private const val SIGNATURE_ALGORITHM = "SHA256withECDSA"
    private const val COORDINATE_BYTES = 32

    private val executor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())
    private val pendingPrompts = ConcurrentHashMap<String, BiometricPrompt>()
    private var methodChannel: MethodChannel? = null
    private var resumedActivityRef = WeakReference<FragmentActivity>(null)

    private class HardwareKeyError(val code: String) : Exception(code)

    private class GeneratedKey(val publicPoint: ByteArray, val backing: String)

    /** Replies at most once, always on the main thread. */
    private class Reply(private val result: MethodChannel.Result) {
        private val replied = AtomicBoolean(false)

        fun success(value: Any?) {
            if (replied.compareAndSet(false, true)) {
                mainHandler.post { result.success(value) }
            }
        }

        fun error(code: String) {
            if (replied.compareAndSet(false, true)) {
                mainHandler.post { result.error(code, null, null) }
            }
        }

        fun notImplemented() {
            if (replied.compareAndSet(false, true)) {
                mainHandler.post { result.notImplemented() }
            }
        }
    }

    private val activityCallbacks = object : Application.ActivityLifecycleCallbacks {
        override fun onActivityResumed(activity: Activity) {
            if (activity is FragmentActivity) {
                resumedActivityRef = WeakReference(activity)
            }
        }

        override fun onActivityPaused(activity: Activity) {
            if (resumedActivityRef.get() === activity) {
                resumedActivityRef.clear()
            }
        }

        override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) = Unit

        override fun onActivityStarted(activity: Activity) = Unit

        override fun onActivityStopped(activity: Activity) = Unit

        override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) = Unit

        override fun onActivityDestroyed(activity: Activity) = Unit
    }

    fun attachToEngine(flutterEngine: FlutterEngine, applicationContext: Context) {
        if (methodChannel != null) {
            return
        }
        (applicationContext as? Application)?.registerActivityLifecycleCallbacks(
            activityCallbacks,
        )
        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).apply {
            setMethodCallHandler { call, result ->
                handleMethodCall(call, Reply(result), applicationContext)
            }
        }
    }

    private fun handleMethodCall(call: MethodCall, reply: Reply, context: Context) {
        when (call.method) {
            "getCapabilities" -> runAsync(reply) { capabilities(context) }
            "generateKey" -> {
                val alias = call.argument<String>("alias")
                if (alias.isNullOrEmpty()) {
                    reply.error("invalid_args")
                    return
                }
                val requireUserPresence = call.argument<Boolean>("requireUserPresence") == true
                runAsync(reply) {
                    if (requireUserPresence && !userPresenceAvailable(context)) {
                        throw HardwareKeyError("user_presence_unavailable")
                    }
                    val generated = try {
                        generateKey(
                            alias = alias,
                            requireUserPresence = requireUserPresence,
                            preferStrongBox = hasStrongBox(context),
                        )
                    } catch (error: InvalidAlgorithmParameterException) {
                        // Keystore refuses per-use keys without an enrolled
                        // biometric or a secure lock screen.
                        if (!requireUserPresence) {
                            throw error
                        }
                        throw HardwareKeyError("user_presence_unavailable")
                    }
                    mapOf(
                        "publicKey" to generated.publicPoint,
                        "backing" to generated.backing,
                        "isEmulator" to isProbablyEmulator(),
                    )
                }
            }
            "sign" -> {
                val alias = call.argument<String>("alias")
                val data = call.argument<ByteArray>("data")
                val requestId = call.argument<String>("requestId")
                if (alias.isNullOrEmpty() || data == null || requestId.isNullOrEmpty()) {
                    reply.error("invalid_args")
                    return
                }
                val reason = call.argument<String>("reason") ?: "Sign in with your SSH key"
                sign(alias, data, reason, requestId, reply)
            }
            "cancelSign" -> {
                call.argument<String>("requestId")?.let { requestId ->
                    pendingPrompts.remove(requestId)?.cancelAuthentication()
                }
                reply.success(null)
            }
            "deleteKey" -> {
                val alias = call.argument<String>("alias")
                if (alias.isNullOrEmpty()) {
                    reply.error("invalid_args")
                    return
                }
                runAsync(reply) {
                    loadKeyStore().deleteEntry(alias)
                    null
                }
            }
            else -> reply.notImplemented()
        }
    }

    private fun runAsync(reply: Reply, operation: () -> Any?) {
        executor.execute {
            try {
                reply.success(operation())
            } catch (error: HardwareKeyError) {
                reply.error(error.code)
            } catch (error: Exception) {
                Log.w(TAG, "Hardware key operation failed: ${error.javaClass.simpleName}")
                reply.error(mapException(error))
            }
        }
    }

    // region Capabilities

    private fun capabilities(context: Context): Map<String, Any?> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            return mapOf("available" to false, "reason" to "osTooOld")
        }
        val emulator = isProbablyEmulator()
        val strongBox = hasStrongBox(context)
        // A throwaway key is the only reliable way to learn where the keystore
        // really puts keys: StrongBox, the TEE, or software.
        val backing = try {
            generateKey(PROBE_ALIAS, requireUserPresence = false, preferStrongBox = strongBox).backing
        } catch (error: HardwareKeyError) {
            if (error.code != "not_hardware_backed") {
                throw error
            }
            null
        } finally {
            try {
                loadKeyStore().deleteEntry(PROBE_ALIAS)
            } catch (error: Exception) {
                Log.w(TAG, "Probe key cleanup failed: ${error.javaClass.simpleName}")
            }
        }
        if (backing == null) {
            return mapOf(
                "available" to false,
                "reason" to if (emulator) "emulator" else "softwareKeystoreOnly",
            )
        }
        return mapOf(
            "available" to true,
            "backing" to backing,
            "userPresenceAvailable" to userPresenceAvailable(context),
            "isEmulator" to emulator,
            "strongBoxAvailable" to strongBox,
        )
    }

    private fun hasStrongBox(context: Context): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.P &&
            context.packageManager.hasSystemFeature(PackageManager.FEATURE_STRONGBOX_KEYSTORE)

    private fun allowedAuthenticators(): Int =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            BiometricManager.Authenticators.BIOMETRIC_STRONG or
                BiometricManager.Authenticators.DEVICE_CREDENTIAL
        } else {
            // Before Android 11 a per-use key can only be unlocked by a
            // strong biometric.
            BiometricManager.Authenticators.BIOMETRIC_STRONG
        }

    private fun userPresenceAvailable(context: Context): Boolean {
        val keyguard = context.getSystemService(KeyguardManager::class.java)
        if (keyguard?.isDeviceSecure != true) {
            return false
        }
        return BiometricManager.from(context).canAuthenticate(allowedAuthenticators()) ==
            BiometricManager.BIOMETRIC_SUCCESS
    }

    private fun isProbablyEmulator(): Boolean =
        Build.FINGERPRINT.startsWith("generic") ||
            Build.FINGERPRINT.contains("emulator") ||
            Build.HARDWARE == "goldfish" ||
            Build.HARDWARE == "ranchu" ||
            Build.MODEL.contains("sdk_gphone") ||
            Build.MODEL.contains("Emulator") ||
            Build.MODEL.contains("Android SDK built for") ||
            Build.PRODUCT.startsWith("sdk") ||
            Build.PRODUCT.contains("emulator")

    // endregion

    // region Keys

    private fun loadKeyStore(): KeyStore = KeyStore.getInstance(KEYSTORE).apply { load(null) }

    private fun generateKey(
        alias: String,
        requireUserPresence: Boolean,
        preferStrongBox: Boolean,
    ): GeneratedKey {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            throw HardwareKeyError("unavailable")
        }
        val keyStore = loadKeyStore()
        if (alias != PROBE_ALIAS && keyStore.containsAlias(alias)) {
            throw HardwareKeyError("failed")
        }
        val generator = KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, KEYSTORE)
        var usedStrongBox = false
        val keyPair = if (preferStrongBox && Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            try {
                generator.initialize(keySpec(alias, requireUserPresence, strongBox = true))
                generator.generateKeyPair().also { usedStrongBox = true }
            } catch (error: StrongBoxUnavailableException) {
                generator.initialize(keySpec(alias, requireUserPresence, strongBox = false))
                generator.generateKeyPair()
            }
        } else {
            generator.initialize(keySpec(alias, requireUserPresence, strongBox = false))
            generator.generateKeyPair()
        }

        val backing = securityBacking(keyPair.private, usedStrongBox)
        if (backing == null) {
            keyStore.deleteEntry(alias)
            throw HardwareKeyError("not_hardware_backed")
        }
        val publicKey = keyPair.public as? ECPublicKey ?: run {
            keyStore.deleteEntry(alias)
            throw HardwareKeyError("failed")
        }
        val point = ByteArray(1 + COORDINATE_BYTES * 2)
        point[0] = 0x04
        unsignedFixed(publicKey.w.affineX).copyInto(point, 1)
        unsignedFixed(publicKey.w.affineY).copyInto(point, 1 + COORDINATE_BYTES)
        return GeneratedKey(point, backing)
    }

    private fun keySpec(
        alias: String,
        requireUserPresence: Boolean,
        strongBox: Boolean,
    ): KeyGenParameterSpec {
        val builder = KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_SIGN)
            .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
            .setDigests(KeyProperties.DIGEST_SHA256)
        if (strongBox && Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            builder.setIsStrongBoxBacked(true)
        }
        if (requireUserPresence) {
            builder.setUserAuthenticationRequired(true)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                builder.setUserAuthenticationParameters(
                    0,
                    KeyProperties.AUTH_BIOMETRIC_STRONG or KeyProperties.AUTH_DEVICE_CREDENTIAL,
                )
            } else {
                @Suppress("DEPRECATION")
                builder.setUserAuthenticationValidityDurationSeconds(-1)
            }
        }
        return builder.build()
    }

    /** Where the keystore actually put [privateKey], or null for software. */
    private fun securityBacking(privateKey: PrivateKey, requestedStrongBox: Boolean): String? {
        val factory = KeyFactory.getInstance(privateKey.algorithm, KEYSTORE)
        val info = factory.getKeySpec(privateKey, KeyInfo::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            return when (info.securityLevel) {
                KeyProperties.SECURITY_LEVEL_STRONGBOX -> "strongBox"
                KeyProperties.SECURITY_LEVEL_TRUSTED_ENVIRONMENT -> "tee"
                KeyProperties.SECURITY_LEVEL_UNKNOWN_SECURE ->
                    if (requestedStrongBox) "strongBox" else "tee"
                else -> null
            }
        }
        @Suppress("DEPRECATION")
        val secure = info.isInsideSecureHardware
        return when {
            !secure -> null
            requestedStrongBox -> "strongBox"
            else -> "tee"
        }
    }

    private fun unsignedFixed(value: BigInteger): ByteArray {
        val bytes = value.toByteArray()
        return when {
            bytes.size == COORDINATE_BYTES -> bytes
            bytes.size == COORDINATE_BYTES + 1 && bytes[0] == 0.toByte() ->
                bytes.copyOfRange(1, bytes.size)
            bytes.size < COORDINATE_BYTES ->
                ByteArray(COORDINATE_BYTES - bytes.size) + bytes
            else -> throw HardwareKeyError("failed")
        }
    }

    // endregion

    // region Signing

    private fun sign(
        alias: String,
        data: ByteArray,
        reason: String,
        requestId: String,
        reply: Reply,
    ) {
        executor.execute {
            try {
                val entry = loadKeyStore().getEntry(alias, null) as? KeyStore.PrivateKeyEntry
                    ?: throw HardwareKeyError("key_not_found")
                val privateKey = entry.privateKey
                val info = KeyFactory.getInstance(privateKey.algorithm, KEYSTORE)
                    .getKeySpec(privateKey, KeyInfo::class.java)
                val signature = Signature.getInstance(SIGNATURE_ALGORITHM).apply {
                    initSign(privateKey)
                }
                if (!info.isUserAuthenticationRequired) {
                    signature.update(data)
                    reply.success(signature.sign())
                    return@execute
                }
                mainHandler.post { promptAndSign(signature, data, reason, requestId, reply) }
            } catch (error: HardwareKeyError) {
                reply.error(error.code)
            } catch (error: Exception) {
                Log.w(TAG, "Hardware key signing failed: ${error.javaClass.simpleName}")
                reply.error(mapException(error))
            }
        }
    }

    private fun promptAndSign(
        signature: Signature,
        data: ByteArray,
        reason: String,
        requestId: String,
        reply: Reply,
    ) {
        val activity = resumedActivityRef.get()
        if (activity == null || activity.isFinishing) {
            // Background reconnects cannot show a prompt.
            reply.error("interaction_required")
            return
        }
        val prompt = BiometricPrompt(
            activity,
            ContextCompat.getMainExecutor(activity),
            object : BiometricPrompt.AuthenticationCallback() {
                override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                    pendingPrompts.remove(requestId)
                    val unlocked = result.cryptoObject?.signature
                    if (unlocked == null) {
                        reply.error("failed")
                        return
                    }
                    executor.execute {
                        try {
                            unlocked.update(data)
                            reply.success(unlocked.sign())
                        } catch (error: Exception) {
                            Log.w(TAG, "Hardware key signing failed: ${error.javaClass.simpleName}")
                            reply.error(mapException(error))
                        }
                    }
                }

                override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                    pendingPrompts.remove(requestId)
                    reply.error(mapPromptError(errorCode))
                }
            },
        )
        val promptInfo = BiometricPrompt.PromptInfo.Builder()
            .setTitle("Use SSH key")
            .setSubtitle(reason)
            .setAllowedAuthenticators(allowedAuthenticators())
            .apply {
                if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
                    setNegativeButtonText("Cancel")
                }
            }
            .build()
        pendingPrompts[requestId] = prompt
        try {
            prompt.authenticate(promptInfo, BiometricPrompt.CryptoObject(signature))
        } catch (error: Exception) {
            pendingPrompts.remove(requestId)
            Log.w(TAG, "Hardware key prompt failed: ${error.javaClass.simpleName}")
            reply.error("failed")
        }
    }

    private fun mapPromptError(errorCode: Int): String = when (errorCode) {
        BiometricPrompt.ERROR_USER_CANCELED,
        BiometricPrompt.ERROR_NEGATIVE_BUTTON,
        BiometricPrompt.ERROR_CANCELED,
        -> "cancelled"
        BiometricPrompt.ERROR_LOCKOUT,
        BiometricPrompt.ERROR_LOCKOUT_PERMANENT,
        -> "auth_failed"
        BiometricPrompt.ERROR_NO_BIOMETRICS,
        BiometricPrompt.ERROR_HW_NOT_PRESENT,
        BiometricPrompt.ERROR_HW_UNAVAILABLE,
        BiometricPrompt.ERROR_NO_DEVICE_CREDENTIAL,
        -> "user_presence_unavailable"
        else -> "failed"
    }

    private fun mapException(error: Exception): String = when (error) {
        is KeyPermanentlyInvalidatedException -> "key_invalidated"
        else -> "failed"
    }

    // endregion
}
