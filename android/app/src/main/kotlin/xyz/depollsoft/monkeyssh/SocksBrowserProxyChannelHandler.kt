package xyz.depollsoft.monkeyssh

import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.webkit.ProxyConfig
import androidx.webkit.ProxyController
import androidx.webkit.WebViewFeature
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executor

/**
 * Routes the app's WebViews through a loopback SOCKS5 forward.
 *
 * `webview_flutter` exposes no proxy settings, so the in-app browser asks for
 * an AndroidX [ProxyController] override here. The override is process-wide
 * and has no direct fallback: when the forward drops, requests fail instead of
 * leaving over the device's own network. Loopback destinations go through the
 * proxy too, so `localhost` means the SSH host's loopback.
 */
object SocksBrowserProxyChannelHandler {
    private const val CHANNEL = "xyz.depollsoft.monkeyssh/socks_browser_proxy"
    private const val TAG = "SocksBrowserProxy"

    private val mainHandler = Handler(Looper.getMainLooper())
    private val mainExecutor = Executor { command -> mainHandler.post(command) }

    fun attachToEngine(engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler(::handle)
    }

    private fun isSupported(): Boolean =
        try {
            WebViewFeature.isFeatureSupported(WebViewFeature.PROXY_OVERRIDE)
        } catch (error: RuntimeException) {
            // No WebView provider is installed or it failed to load.
            Log.w(TAG, "Proxy support check failed: ${error.javaClass.simpleName}")
            false
        }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "isSupported" -> result.success(isSupported())
            "apply" -> apply(call, result)
            "clear" -> clear(result)
            else -> result.notImplemented()
        }
    }

    private fun apply(call: MethodCall, result: MethodChannel.Result) {
        val port = call.argument<Int>("port")
        if (port == null || port !in 1..65535) {
            result.error("invalid_port", "SOCKS port is out of range", null)
            return
        }
        try {
            // Checked inline so lint can see the feature guard.
            if (!WebViewFeature.isFeatureSupported(WebViewFeature.PROXY_OVERRIDE)) {
                result.error("unsupported", "WebView proxy override is unavailable", null)
                return
            }
            val config =
                ProxyConfig.Builder()
                    .addProxyRule("socks5://127.0.0.1:$port")
                    // Without this, localhost and loopback addresses would
                    // load from the device instead of the SSH host.
                    .removeImplicitRules()
                    .build()
            ProxyController.getInstance().setProxyOverride(config, mainExecutor) {
                result.success(null)
            }
        } catch (error: RuntimeException) {
            Log.w(TAG, "Proxy override failed: ${error.javaClass.simpleName}")
            result.error("apply_failed", error.javaClass.simpleName, null)
        }
    }

    private fun clear(result: MethodChannel.Result) {
        try {
            if (!WebViewFeature.isFeatureSupported(WebViewFeature.PROXY_OVERRIDE)) {
                result.success(null)
                return
            }
            ProxyController.getInstance().clearProxyOverride(mainExecutor) {
                result.success(null)
            }
        } catch (error: RuntimeException) {
            Log.w(TAG, "Proxy clear failed: ${error.javaClass.simpleName}")
            result.error("clear_failed", error.javaClass.simpleName, null)
        }
    }
}
