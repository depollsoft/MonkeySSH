package xyz.depollsoft.monkeyssh

import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.webkit.ProfileStore
import androidx.webkit.ProxyConfig
import androidx.webkit.ProxyController
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugins.webviewflutter.WebViewFlutterAndroidExternalApi
import java.util.UUID
import java.util.concurrent.Executor

/**
 * Routes the app's WebViews through a loopback SOCKS5 forward, and keeps each
 * saved host's SOCKS pages in their own WebView profile.
 *
 * `webview_flutter` exposes no proxy settings, so the in-app browser asks for
 * an AndroidX [ProxyController] override here. The override is process-wide
 * (every profile uses it) and has no direct fallback: when the forward drops,
 * requests fail instead of leaving over the device's own network. Loopback
 * destinations go through the proxy too, so `localhost` means the SSH host's
 * loopback.
 *
 * Pages reached through SOCKS keep their real origins, so the browser gives
 * each host a profile of its own (cookies, storage, cache, HTTP auth) named
 * `monkeyssh-socks-<random id>`. Without multi-profile support there is no
 * safe place for those pages, so SOCKS browsing is reported unsupported.
 */
object SocksBrowserProxyChannelHandler {
    private const val CHANNEL = "xyz.depollsoft.monkeyssh/socks_browser_proxy"
    private const val TAG = "SocksBrowserProxy"
    private const val PROFILE_PREFIX = "monkeyssh-socks-"

    private val mainHandler = Handler(Looper.getMainLooper())
    private val mainExecutor = Executor { command -> mainHandler.post(command) }

    fun attachToEngine(engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result -> handle(engine, call, result) }
    }

    private fun isSupported(): Boolean =
        try {
            WebViewFeature.isFeatureSupported(WebViewFeature.PROXY_OVERRIDE) &&
                WebViewFeature.isFeatureSupported(WebViewFeature.MULTI_PROFILE)
        } catch (error: RuntimeException) {
            // No WebView provider is installed or it failed to load.
            Log.w(TAG, "Proxy support check failed: ${error.javaClass.simpleName}")
            false
        }

    private fun handle(engine: FlutterEngine, call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "isSupported" -> result.success(isSupported())
            "apply" -> apply(call, result)
            "clear" -> clear(result)
            "attachDataStore" -> attachDataStore(engine, call, result)
            "deleteDataStore" -> deleteDataStore(call, result)
            "listDataStores" -> listDataStores(result)
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

    /** The profile for the call's `store` id, or null unless it is a lowercase UUID. */
    private fun profileName(call: MethodCall): String? {
        val store = call.argument<String>("store") ?: return null
        return try {
            if (UUID.fromString(store).toString() == store) PROFILE_PREFIX + store else null
        } catch (error: IllegalArgumentException) {
            null
        }
    }

    /**
     * Moves a WebView the browser just created into the store's profile. A
     * profile can only be set before the WebView loads anything, so the
     * browser calls this before configuring or loading it.
     */
    private fun attachDataStore(
        engine: FlutterEngine,
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        val profile = profileName(call)
        val webViewId = call.argument<Number>("webView")?.toLong()
        if (profile == null || webViewId == null) {
            result.error("invalid_store", "Store or web view id is invalid", null)
            return
        }
        try {
            if (!WebViewFeature.isFeatureSupported(WebViewFeature.MULTI_PROFILE)) {
                result.error("unsupported", "WebView profiles are unavailable", null)
                return
            }
            @Suppress("DEPRECATION")
            val webView = WebViewFlutterAndroidExternalApi.getWebView(engine, webViewId)
            if (webView == null) {
                result.error("webview_missing", "The web view is gone", null)
                return
            }
            WebViewCompat.setProfile(webView, profile)
            if (WebViewCompat.getProfile(webView).name != profile) {
                result.error("store_mismatch", "The web view kept another profile", null)
                return
            }
            result.success(null)
        } catch (error: RuntimeException) {
            // IllegalStateException when the WebView was already used.
            Log.w(TAG, "Profile attach failed: ${error.javaClass.simpleName}")
            result.error("attach_failed", error.javaClass.simpleName, null)
        }
    }

    private fun deleteDataStore(call: MethodCall, result: MethodChannel.Result) {
        val profile = profileName(call)
        if (profile == null) {
            result.error("invalid_store", "Store id is invalid", null)
            return
        }
        try {
            if (!WebViewFeature.isFeatureSupported(WebViewFeature.MULTI_PROFILE)) {
                // No profiles, so none was ever created.
                result.success(null)
                return
            }
            // False only when the profile does not exist.
            ProfileStore.getInstance().deleteProfile(profile)
            result.success(null)
        } catch (error: IllegalStateException) {
            // A WebView still uses the profile; the browser retries later.
            result.error("in_use", "The profile is still in use", null)
        } catch (error: RuntimeException) {
            Log.w(TAG, "Profile delete failed: ${error.javaClass.simpleName}")
            result.error("delete_failed", error.javaClass.simpleName, null)
        }
    }

    private fun listDataStores(result: MethodChannel.Result) {
        try {
            if (!WebViewFeature.isFeatureSupported(WebViewFeature.MULTI_PROFILE)) {
                result.success(emptyList<String>())
                return
            }
            val stores =
                ProfileStore.getInstance().allProfileNames
                    .filter { it.startsWith(PROFILE_PREFIX) }
                    .map { it.removePrefix(PROFILE_PREFIX) }
            result.success(stores)
        } catch (error: RuntimeException) {
            Log.w(TAG, "Profile list failed: ${error.javaClass.simpleName}")
            result.error("list_failed", error.javaClass.simpleName, null)
        }
    }
}
