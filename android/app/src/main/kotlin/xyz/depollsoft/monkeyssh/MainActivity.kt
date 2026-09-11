package xyz.depollsoft.monkeyssh

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.OpenableColumns
import android.util.Log
import android.view.KeyCharacterMap
import android.view.KeyEvent
import androidx.core.content.ContextCompat
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMethodCodec
import java.io.ByteArrayOutputStream
import java.util.Locale
import java.util.concurrent.Executors

class MainActivity : FlutterFragmentActivity() {
    companion object {
        private val transferExecutor = Executors.newSingleThreadExecutor()
        private const val NOTIFICATION_PERMISSION_REQUEST_CODE = 1001
        private const val MAX_CLIPBOARD_CONTENT_URI_BYTES = 512 * 1024
        private const val MONKEYSSH_TRANSFER_MIME_TYPE = "application/x-monkeyssh-transfer"
        private const val MONKEYSSH_TRANSFER_EXTENSION = ".monkeysshx"
        private const val TERMINAL_IME_KEY_CHANNEL =
            "xyz.depollsoft.monkeyssh/terminal_ime_keys"
        private const val KEYBOARD_VISIBILITY_CHANNEL =
            "xyz.depollsoft.monkeyssh/keyboard_visibility"
    }

    private val clipboardChannel = "xyz.depollsoft.monkeyssh/clipboard_content"
    private val transferChannel = "xyz.depollsoft.monkeyssh/transfer"
    private val maxTransferPayloadBytes = 10 * 1024 * 1024
    private var clipboardMethodChannel: MethodChannel? = null
    private var transferMethodChannel: MethodChannel? = null
    private var terminalImeKeyMethodChannel: MethodChannel? = null
    private var keyboardVisibilityMethodChannel: MethodChannel? = null
    private var terminalImeKeyInterceptionEnabled = false
    private var pendingTransferPayload: String? = null
    private var transferGeneration = 0
    private var hasRequestedNotificationPermission = false

    override fun onCreate(savedInstanceState: Bundle?) {
        MonkeySshApplication.from(this).ensureSharedFlutterEngine()
        super.onCreate(savedInstanceState)
        SshServiceChannelHandler.attachActivity(this)
        installKeyboardVisibilityListener()
        handleTransferIntent(intent)
    }

    override fun getCachedEngineId(): String {
        MonkeySshApplication.from(this).ensureSharedFlutterEngine()
        return MonkeySshApplication.SHARED_ENGINE_ID
    }

    override fun shouldDestroyEngineWithHost(): Boolean = false

    override fun getInitialRoute(): String? {
        if (isTransferIntent(intent)) {
            return "/"
        }
        return super.getInitialRoute()
    }

    override fun shouldHandleDeeplinking(): Boolean {
        if (isTransferIntent(intent)) {
            return false
        }
        return super.shouldHandleDeeplinking()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        clipboardMethodChannel =
            MethodChannel(
                flutterEngine.dartExecutor.binaryMessenger,
                clipboardChannel,
                StandardMethodCodec.INSTANCE,
                // Content providers can block on disk, another process, or the network.
                flutterEngine.dartExecutor.binaryMessenger.makeBackgroundTaskQueue(),
            )
        clipboardMethodChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "readContentUri" -> {
                    val uriString = call.argument<String>("uri")
                    if (uriString.isNullOrBlank()) {
                        result.error("invalid_uri", "Clipboard URI was missing", null)
                        return@setMethodCallHandler
                    }
                    try {
                        result.success(readClipboardContentUri(Uri.parse(uriString)))
                    } catch (error: Exception) {
                        result.error(
                            "clipboard_read_failed",
                            error.message ?: "Failed to read clipboard URI",
                            null,
                        )
                    }
                }

                else -> {
                    result.notImplemented()
                }
            }
        }

        transferMethodChannel =
            MethodChannel(
                flutterEngine.dartExecutor.binaryMessenger,
                transferChannel,
            )
        transferMethodChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "consumeIncomingTransferPayload" -> {
                    result.success(pendingTransferPayload)
                    pendingTransferPayload = null
                }

                else -> {
                    result.notImplemented()
                }
            }
        }

        terminalImeKeyMethodChannel =
            MethodChannel(
                flutterEngine.dartExecutor.binaryMessenger,
                TERMINAL_IME_KEY_CHANNEL,
            )
        terminalImeKeyMethodChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "setInterceptionEnabled" -> {
                    terminalImeKeyInterceptionEnabled = call.arguments == true
                    result.success(null)
                }

                else -> {
                    result.notImplemented()
                }
            }
        }
        keyboardVisibilityMethodChannel =
            MethodChannel(
                flutterEngine.dartExecutor.binaryMessenger,
                KEYBOARD_VISIBILITY_CHANNEL,
            )
        keyboardVisibilityMethodChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "getVisibility" -> result.success(keyboardVisible)
                else -> result.notImplemented()
            }
        }

        terminalImeKeyMethodChannel?.invokeMethod(
            "getInterceptionEnabled",
            null,
            object : MethodChannel.Result {
                override fun success(result: Any?) {
                    terminalImeKeyInterceptionEnabled = result == true
                }

                override fun error(
                    errorCode: String,
                    errorMessage: String?,
                    errorDetails: Any?,
                ) {
                    terminalImeKeyInterceptionEnabled = false
                }

                override fun notImplemented() {
                    terminalImeKeyInterceptionEnabled = false
                }
            },
        )

        notifyIncomingTransferPayload()
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        val channel = terminalImeKeyMethodChannel
        val key = terminalImeKeyName(event)
        val type =
            when {
                event.action == KeyEvent.ACTION_UP -> "release"
                event.action == KeyEvent.ACTION_DOWN && event.repeatCount > 0 -> "repeat"
                event.action == KeyEvent.ACTION_DOWN -> "press"
                else -> null
            }
        if (
            terminalImeKeyInterceptionEnabled &&
            channel != null &&
            key != null &&
            type != null
        ) {
            if (isVirtualKeyboardEvent(event)) {
                channel.invokeMethod(
                    "onVirtualKeyEvent",
                    mapOf("key" to key, "type" to type),
                )
                return true
            }
            channel.invokeMethod(
                "onPhysicalKeyEvent",
                mapOf("key" to key, "type" to type),
                object : MethodChannel.Result {
                    override fun success(result: Any?) {
                        redispatchPhysicalKeyEvent(event)
                    }

                    override fun error(
                        errorCode: String,
                        errorMessage: String?,
                        errorDetails: Any?,
                    ) {
                        redispatchPhysicalKeyEvent(event)
                    }

                    override fun notImplemented() {
                        redispatchPhysicalKeyEvent(event)
                    }
                },
            )
            return true
        }
        return super.dispatchKeyEvent(event)
    }

    private fun redispatchPhysicalKeyEvent(event: KeyEvent) {
        runOnUiThread {
            super.dispatchKeyEvent(event)
        }
    }

    override fun onStart() {
        super.onStart()
        SshConnectionService.setActivityVisible(true)
    }

    override fun onResume() {
        super.onResume()
        SshConnectionService.setForegroundState(applicationContext, true)
        // The "tap to return" prompt has done its job once the app is visible.
        DeviceDebugChannelHandler.hideReturnPrompt(applicationContext)
    }

    override fun onPause() {
        // Request foreground service while Android still considers us visible.
        SshConnectionService.setForegroundState(applicationContext, false)
        super.onPause()
    }

    override fun onStop() {
        SshConnectionService.setActivityVisible(false)
        super.onStop()
    }

    override fun onNewIntent(intent: Intent) {
        setIntent(intent)
        super.onNewIntent(intent)
        handleTransferIntent(intent)
    }

    override fun onDestroy() {
        transferGeneration++
        ViewCompat.setOnApplyWindowInsetsListener(window.decorView, null)
        SshServiceChannelHandler.detachActivity(this)
        clipboardMethodChannel?.setMethodCallHandler(null)
        clipboardMethodChannel = null
        transferMethodChannel?.setMethodCallHandler(null)
        transferMethodChannel = null
        terminalImeKeyInterceptionEnabled = false
        terminalImeKeyMethodChannel?.setMethodCallHandler(null)
        terminalImeKeyMethodChannel = null
        keyboardVisibilityMethodChannel?.setMethodCallHandler(null)
        keyboardVisibilityMethodChannel = null
        super.onDestroy()
    }

    private fun terminalImeKeyName(event: KeyEvent): String? =
        when (event.keyCode) {
            KeyEvent.KEYCODE_SHIFT_LEFT -> "shiftLeft"
            KeyEvent.KEYCODE_SHIFT_RIGHT -> "shiftRight"
            KeyEvent.KEYCODE_DEL -> "backspace"
            else -> null
        }

    private fun isVirtualKeyboardEvent(event: KeyEvent): Boolean =
        event.deviceId == KeyCharacterMap.VIRTUAL_KEYBOARD ||
            event.device?.isVirtual == true

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (
            requestCode == NOTIFICATION_PERMISSION_REQUEST_CODE &&
            grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED
        ) {
            SshConnectionService.refresh(this)
        }
    }

    fun ensureNotificationPermission() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            return
        }
        if (
            ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.POST_NOTIFICATIONS,
            ) == PackageManager.PERMISSION_GRANTED
        ) {
            return
        }
        if (hasRequestedNotificationPermission) {
            return
        }
        hasRequestedNotificationPermission = true
        requestPermissions(
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            NOTIFICATION_PERMISSION_REQUEST_CODE,
        )
    }

    private fun handleTransferIntent(intent: Intent?) {
        if (!isTransferIntent(intent)) {
            return
        }

        val transferIntent = intent ?: return
        val sourceUri = transferIntent.data ?: return
        val generation = ++transferGeneration
        pendingTransferPayload = null
        transferExecutor.execute {
            val payload = try {
                if (hasTransferExtension(sourceUri)) {
                    readBoundedContent(
                        sourceUri,
                        maxTransferPayloadBytes,
                        "Transfer payload exceeds ${maxTransferPayloadBytes / 1024} KB limit",
                    )?.toString(Charsets.UTF_8)
                } else {
                    null
                }
            } catch (error: Exception) {
                Log.w("MainActivity", "Transfer read failed: ${error.javaClass.simpleName}")
                null
            }
            runOnUiThread {
                if (generation == transferGeneration && !isDestroyed) {
                    pendingTransferPayload = payload
                    notifyIncomingTransferPayload()
                }
            }
        }
    }

    /**
     * Reads a content URI fully, or null when it cannot be opened. Throws
     * [IllegalStateException] with [limitMessage] once [maxBytes] is exceeded.
     */
    private fun readBoundedContent(
        uri: Uri,
        maxBytes: Int,
        limitMessage: String,
    ): ByteArray? =
        contentResolver.openInputStream(uri)?.use { stream ->
            val buffer = ByteArray(8192)
            val output = ByteArrayOutputStream()
            var bytesRead: Int
            var totalBytes = 0
            while (stream.read(buffer).also { bytesRead = it } != -1) {
                totalBytes += bytesRead
                if (totalBytes > maxBytes) {
                    throw IllegalStateException(limitMessage)
                }
                output.write(buffer, 0, bytesRead)
            }
            output.toByteArray()
        }

    private var keyboardVisible = false

    private fun installKeyboardVisibilityListener() {
        ViewCompat.setOnApplyWindowInsetsListener(window.decorView) { _, insets ->
            val visible = insets.isVisible(WindowInsetsCompat.Type.ime())
            if (visible != keyboardVisible) {
                keyboardVisible = visible
                keyboardVisibilityMethodChannel?.invokeMethod(
                    "onVisibilityChanged",
                    visible,
                )
            }
            insets
        }
        ViewCompat.requestApplyInsets(window.decorView)
    }

    private fun notifyIncomingTransferPayload() {
        val payload = pendingTransferPayload ?: return
        transferMethodChannel?.invokeMethod("onIncomingTransferPayload", payload)
    }

    private fun isTransferIntent(intent: Intent?): Boolean {
        val transferIntent = intent ?: return false
        if (transferIntent.action != Intent.ACTION_VIEW) {
            return false
        }
        val sourceUri = transferIntent.data ?: return false
        if (sourceUri.scheme != "content") {
            return false
        }
        val mimeType = transferIntent.type?.lowercase(Locale.ROOT)
        if (mimeType != MONKEYSSH_TRANSFER_MIME_TYPE) {
            return false
        }
        // Routing runs during activity startup; provider metadata is read on the worker.
        return true
    }

    private fun hasTransferExtension(sourceUri: Uri): Boolean {
        val lastPathSegment = sourceUri.lastPathSegment?.lowercase(Locale.ROOT)
        if (lastPathSegment?.endsWith(MONKEYSSH_TRANSFER_EXTENSION) == true) {
            return true
        }
        val displayName =
            runCatching { resolveContentMetadata(sourceUri)?.displayName }
                .getOrNull()
                ?.lowercase(Locale.ROOT)
        return displayName == null || displayName.endsWith(MONKEYSSH_TRANSFER_EXTENSION)
    }

    private fun readClipboardContentUri(uri: Uri): Map<String, Any> {
        val metadata = resolveContentMetadata(uri)
        val displayName =
            metadata?.displayName ?: uri.lastPathSegment?.substringAfterLast('/') ?: "clipboard-file"
        val limitMessage =
            "Clipboard content exceeds ${MAX_CLIPBOARD_CONTENT_URI_BYTES / 1024} KB limit"
        val contentLength = metadata?.size
        if (contentLength != null && contentLength > MAX_CLIPBOARD_CONTENT_URI_BYTES) {
            throw IllegalStateException(limitMessage)
        }
        val bytes =
            readBoundedContent(uri, MAX_CLIPBOARD_CONTENT_URI_BYTES, limitMessage)
                ?: throw IllegalStateException("Could not open clipboard URI")
        return mapOf(
            "name" to displayName,
            "bytes" to bytes,
        )
    }

    private data class ContentMetadata(val displayName: String?, val size: Long?)

    private fun resolveContentMetadata(uri: Uri): ContentMetadata? {
        if (uri.scheme != "content") {
            return null
        }
        val columns = arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE)
        contentResolver.query(uri, columns, null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) {
                val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                val sizeIndex = cursor.getColumnIndex(OpenableColumns.SIZE)
                return ContentMetadata(
                    displayName = if (nameIndex >= 0) cursor.getString(nameIndex) else null,
                    size =
                        if (sizeIndex >= 0 && !cursor.isNull(sizeIndex)) cursor.getLong(sizeIndex)
                        else null,
                )
            }
        }
        return null
    }
}
