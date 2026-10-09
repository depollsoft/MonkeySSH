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
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Non-exportable P-256 SSH keys in Android Keystore, in StrongBox when the
 * device has one and in the TEE otherwise.
 *
 * Only the alias and public key leave this class. It never logs key material,
 * signatures, aliases, or the data being signed.
 *
 * Every androidx BiometricPrompt on an activity shares one view model, so a
 * second prompt would replace the first one's callback and leave that sign
 * request without a reply. Sign requests are therefore tracked on the main
 * thread from the moment the channel receives them, and at most one prompt
 * shows at a time; the Dart side keeps the app lock's prompt out of the way.
 */
object HardwareKeyChannelHandler {
    private const val CHANNEL = "xyz.depollsoft.monkeyssh/hardware_keys"
    private const val TAG = "HardwareKeyChannel"
    private const val KEYSTORE = "AndroidKeyStore"

    /** Every alias the app creates starts with this; nothing else is touched. */
    private const val ALIAS_PREFIX = "xyz.depollsoft.monkeyssh.sshkey."
    private const val PROBE_ALIAS = "${ALIAS_PREFIX}capability-probe"
    private const val SIGNATURE_ALGORITHM = "SHA256withECDSA"
    private const val COORDINATE_BYTES = 32

    /** Lets a dismissed prompt's fragment finish before the next one shows. */
    private const val PROMPT_GAP_MS = 300L

    private val executor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())
    private var methodChannel: MethodChannel? = null
    private var resumedActivityRef = WeakReference<FragmentActivity>(null)

    // Main thread only.
    private val signRequests = HashMap<String, SignRequest>()
    private val promptQueue = ArrayDeque<SignRequest>()
    private var activePrompt: SignRequest? = null

    // Executor thread only: the backing does not change while the app runs,
    // and probing StrongBox can take seconds.
    private var backingProbed = false
    private var probedBacking: String? = null

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

    private class SignRequest(
        val id: String,
        val alias: String,
        val data: ByteArray,
        val reason: String,
        val reply: Reply,
    ) {
        /** Written on the main thread; read when preparation finishes. */
        @Volatile
        var cancelled = false
        var signature: Signature? = null
        var allowDeviceCredential = false
        var prompt: BiometricPrompt? = null
    }

    private val activityCallbacks = object : Application.ActivityLifecycleCallbacks {
        override fun onActivityResumed(activity: Activity) {
            if (activity is FragmentActivity) {
                resumedActivityRef = WeakReference(activity)
                pumpPrompts()
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

    private fun isAppAlias(alias: String?): Boolean =
        alias != null && alias.startsWith(ALIAS_PREFIX) && alias.length > ALIAS_PREFIX.length

    private fun handleMethodCall(call: MethodCall, reply: Reply, context: Context) {
        when (call.method) {
            "getCapabilities" -> runAsync(reply) { capabilities(context) }
            "generateKey" -> {
                val alias = call.argument<String>("alias")
                if (!isAppAlias(alias) || alias == PROBE_ALIAS) {
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
                            alias = alias!!,
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
                if (!isAppAlias(alias) || data == null || requestId.isNullOrEmpty() ||
                    signRequests.containsKey(requestId)
                ) {
                    reply.error("invalid_args")
                    return
                }
                val request = SignRequest(
                    id = requestId,
                    alias = alias!!,
                    data = data,
                    reason = call.argument<String>("reason") ?: "Sign in with your SSH key",
                    reply = reply,
                )
                // Registered before any work, so an early cancel is never lost.
                signRequests[requestId] = request
                executor.execute { prepare(request) }
            }
            "cancelSign" -> {
                call.argument<String>("requestId")?.let(::cancel)
                reply.success(null)
            }
            "deleteKey" -> {
                val alias = call.argument<String>("alias")
                if (!isAppAlias(alias)) {
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
        val backing = probeBacking(strongBox)
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
            // Before Android 11 a per-use key accepts only a strong biometric.
            "userPresenceAllowsPasscode" to (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R),
            "isEmulator" to emulator,
            "strongBoxAvailable" to strongBox,
        )
    }

    /**
     * A throwaway key is the only reliable way to learn where the keystore
     * really puts keys: StrongBox, the TEE, or software. Runs once per process.
     */
    private fun probeBacking(strongBox: Boolean): String? {
        if (backingProbed) {
            return probedBacking
        }
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
        probedBacking = backing
        backingProbed = true
        return backing
    }

    private fun hasStrongBox(context: Context): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.P &&
            context.packageManager.hasSystemFeature(PackageManager.FEATURE_STRONGBOX_KEYSTORE)

    private fun authenticators(allowDeviceCredential: Boolean): Int =
        if (allowDeviceCredential) {
            BiometricManager.Authenticators.BIOMETRIC_STRONG or
                BiometricManager.Authenticators.DEVICE_CREDENTIAL
        } else {
            BiometricManager.Authenticators.BIOMETRIC_STRONG
        }

    private fun userPresenceAvailable(context: Context): Boolean {
        val keyguard = context.getSystemService(KeyguardManager::class.java)
        if (keyguard?.isDeviceSecure != true) {
            return false
        }
        val allowDeviceCredential = Build.VERSION.SDK_INT >= Build.VERSION_CODES.R
        return BiometricManager.from(context).canAuthenticate(
            authenticators(allowDeviceCredential),
        ) == BiometricManager.BIOMETRIC_SUCCESS
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
                // The screen lock already unlocks this key, so a new
                // fingerprint adds no access; keep the key, as iOS does.
                builder.setInvalidatedByBiometricEnrollment(false)
            } else {
                // Biometric only, and invalidated when biometrics are
                // enrolled; the Generate tab says so on Android 10 and
                // earlier.
                @Suppress("DEPRECATION")
                builder.setUserAuthenticationValidityDurationSeconds(-1)
            }
        }
        return builder.build()
    }

    private fun keyInfo(privateKey: PrivateKey): KeyInfo =
        KeyFactory.getInstance(privateKey.algorithm, KEYSTORE)
            .getKeySpec(privateKey, KeyInfo::class.java)

    /** Where the keystore actually put [privateKey], or null for software. */
    private fun securityBacking(privateKey: PrivateKey, requestedStrongBox: Boolean): String? {
        val info = keyInfo(privateKey)
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

    /** Ends [request]; main thread. */
    private fun finish(request: SignRequest, signature: ByteArray? = null, error: String? = null) {
        signRequests.remove(request.id)
        if (signature != null) {
            request.reply.success(signature)
        } else {
            request.reply.error(error ?: "failed")
        }
    }

    /** Executor thread: loads the key and decides whether a prompt is needed. */
    private fun prepare(request: SignRequest) {
        try {
            if (request.cancelled) {
                mainHandler.post { finish(request, error = "cancelled") }
                return
            }
            val entry = loadKeyStore().getEntry(request.alias, null) as? KeyStore.PrivateKeyEntry
                ?: throw HardwareKeyError("key_not_found")
            val privateKey = entry.privateKey
            val info = keyInfo(privateKey)
            val signature = Signature.getInstance(SIGNATURE_ALGORITHM).apply {
                initSign(privateKey)
            }
            if (!info.isUserAuthenticationRequired) {
                signature.update(request.data)
                val signed = signature.sign()
                mainHandler.post { finish(request, signature = signed) }
                return
            }
            request.signature = signature
            // A key made on Android 10 or earlier stays biometric-only
            // after an upgrade; offering the screen lock would only fail.
            request.allowDeviceCredential = Build.VERSION.SDK_INT >= Build.VERSION_CODES.R &&
                (info.userAuthenticationType and KeyProperties.AUTH_DEVICE_CREDENTIAL) != 0
            mainHandler.post {
                if (request.cancelled) {
                    finish(request, error = "cancelled")
                } else {
                    promptQueue.addLast(request)
                    pumpPrompts()
                }
            }
        } catch (error: HardwareKeyError) {
            mainHandler.post { finish(request, error = error.code) }
        } catch (error: Exception) {
            Log.w(TAG, "Hardware key signing failed: ${error.javaClass.simpleName}")
            val code = mapException(error)
            mainHandler.post { finish(request, error = code) }
        }
    }

    /** Main thread: shows the next queued prompt once none is showing. */
    private fun pumpPrompts() {
        if (activePrompt != null) {
            return
        }
        while (true) {
            val request = promptQueue.removeFirstOrNull() ?: return
            if (request.cancelled) {
                finish(request, error = "cancelled")
                continue
            }
            val activity = resumedActivityRef.get()
            if (activity == null || activity.isFinishing) {
                // Background reconnects cannot show a prompt.
                finish(request, error = "interaction_required")
                continue
            }
            showPrompt(request, activity)
            return
        }
    }

    private fun promptEnded(request: SignRequest) {
        if (activePrompt === request) {
            activePrompt = null
            mainHandler.postDelayed({ pumpPrompts() }, PROMPT_GAP_MS)
        }
    }

    private fun showPrompt(request: SignRequest, activity: FragmentActivity) {
        val signature = request.signature ?: run {
            finish(request, error = "failed")
            return
        }
        val prompt = BiometricPrompt(
            activity,
            ContextCompat.getMainExecutor(activity),
            object : BiometricPrompt.AuthenticationCallback() {
                override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                    promptEnded(request)
                    val unlocked = result.cryptoObject?.signature
                    if (unlocked == null || request.cancelled) {
                        finish(request, error = if (request.cancelled) "cancelled" else "failed")
                        return
                    }
                    executor.execute {
                        try {
                            unlocked.update(request.data)
                            val signed = unlocked.sign()
                            mainHandler.post { finish(request, signature = signed) }
                        } catch (error: Exception) {
                            Log.w(TAG, "Hardware key signing failed: ${error.javaClass.simpleName}")
                            val code = mapException(error)
                            mainHandler.post { finish(request, error = code) }
                        }
                    }
                }

                override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                    promptEnded(request)
                    finish(request, error = mapPromptError(errorCode))
                }
            },
        )
        val promptInfo = BiometricPrompt.PromptInfo.Builder()
            .setTitle("Use SSH key")
            .setSubtitle(request.reason)
            .setAllowedAuthenticators(authenticators(request.allowDeviceCredential))
            .apply {
                if (!request.allowDeviceCredential) {
                    setNegativeButtonText("Cancel")
                }
            }
            .build()
        request.prompt = prompt
        activePrompt = request
        try {
            prompt.authenticate(promptInfo, BiometricPrompt.CryptoObject(signature))
        } catch (error: Exception) {
            Log.w(TAG, "Hardware key prompt failed: ${error.javaClass.simpleName}")
            promptEnded(request)
            finish(request, error = "failed")
        }
    }

    /** Main thread: cancels a request at any stage. */
    private fun cancel(requestId: String) {
        val request = signRequests[requestId] ?: return
        request.cancelled = true
        when {
            // The prompt's error callback replies.
            activePrompt === request -> request.prompt?.cancelAuthentication()
            promptQueue.remove(request) -> finish(request, error = "cancelled")
            // Still preparing: prepare() sees the flag before queueing.
            else -> Unit
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
