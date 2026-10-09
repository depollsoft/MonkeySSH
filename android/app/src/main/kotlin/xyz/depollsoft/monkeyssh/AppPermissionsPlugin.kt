package xyz.depollsoft.monkeyssh

import android.Manifest
import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.Settings
import android.util.Log
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry

/**
 * Camera, microphone and foreground-location permissions for the
 * `xyz.depollsoft.monkeyssh/permissions` channel (`AppPermissionService` in Dart).
 *
 * Requests run one at a time, because Android answers a `requestPermissions`
 * call made while another dialog is showing with an empty result.
 */
class AppPermissionsPlugin :
    FlutterPlugin,
    ActivityAware,
    MethodChannel.MethodCallHandler,
    PluginRegistry.RequestPermissionsResultListener {
    companion object {
        private const val CHANNEL = "xyz.depollsoft.monkeyssh/permissions"
        private const val TAG = "AppPermissions"

        /** Fits the 16 bits FragmentActivity allows; MainActivity uses 1001. */
        private const val REQUEST_CODE = 4790

        /**
         * permission_handler kept a "denied before" flag under this key, in a
         * preferences file named after each manifest permission. Using the same
         * store means a permission the user permanently denied before this
         * channel replaced the plugin still reads as permanently denied.
         */
        private const val DENIED_BEFORE_KEY =
            "sp_permission_handler_permission_was_denied_before"

        private const val STATUS_GRANTED = "granted"
        private const val STATUS_DENIED = "denied"
        private const val STATUS_PERMANENTLY_DENIED = "permanentlyDenied"
    }

    private enum class AppPermission(
        val wireName: String,
        val manifestNames: Array<String>,
    ) {
        CAMERA("camera", arrayOf(Manifest.permission.CAMERA)),
        MICROPHONE("microphone", arrayOf(Manifest.permission.RECORD_AUDIO)),

        // Android 12+ ignores a fine-location request that does not also
        // name coarse location. Fine location is what Wi-Fi SSID reads need.
        LOCATION_WHEN_IN_USE(
            "locationWhenInUse",
            arrayOf(
                Manifest.permission.ACCESS_COARSE_LOCATION,
                Manifest.permission.ACCESS_FINE_LOCATION,
            ),
        ),
        ;

        companion object {
            fun fromWireName(name: Any?): AppPermission? =
                entries.firstOrNull { it.wireName == name }
        }
    }

    private class PermissionRequest(
        val permission: AppPermission,
        val result: MethodChannel.Result,
    ) {
        /** `shouldShowRequestPermissionRationale` per manifest name, before asking. */
        var rationaleBefore = BooleanArray(0)
    }

    private var channel: MethodChannel? = null
    private var applicationContext: Context? = null
    private var activityBinding: ActivityPluginBinding? = null
    private var activeRequest: PermissionRequest? = null
    private val queuedRequests = ArrayDeque<PermissionRequest>()

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        applicationContext = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL).also {
            it.setMethodCallHandler(this)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        applicationContext = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        binding.addRequestPermissionsResultListener(this)
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        onAttachedToActivity(binding)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        // The recreated activity receives the pending result, so keep waiting.
        detachActivity()
    }

    override fun onDetachedFromActivity() {
        detachActivity()
        // No activity will deliver a result now. Answer from the current grant
        // state so the Dart future never hangs.
        activeRequest?.let { request ->
            activeRequest = null
            request.result.success(currentStatus(request.permission))
        }
        startNextRequest()
    }

    private fun detachActivity() {
        activityBinding?.removeRequestPermissionsResultListener(this)
        activityBinding = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "request" -> {
                val permission = AppPermission.fromWireName(call.arguments)
                if (permission == null) {
                    result.error("invalid_args", "Unknown permission", call.arguments)
                    return
                }
                queuedRequests.addLast(PermissionRequest(permission, result))
                startNextRequest()
            }
            "openAppSettings" -> result.success(openAppSettings())
            else -> result.notImplemented()
        }
    }

    private fun startNextRequest() {
        while (activeRequest == null) {
            val request = queuedRequests.removeFirstOrNull() ?: return
            val names = request.permission.manifestNames
            val context = activityBinding?.activity ?: applicationContext
            if (context != null && names.all { isGranted(context, it) }) {
                names.forEach { clearDeniedBefore(context, it) }
                request.result.success(STATUS_GRANTED)
                continue
            }
            val activity = promptableActivity()
            if (activity == null) {
                // Nothing on screen can host the dialog, so report without asking.
                request.result.success(currentStatus(request.permission))
                continue
            }
            request.rationaleBefore = BooleanArray(names.size) {
                ActivityCompat.shouldShowRequestPermissionRationale(activity, names[it])
            }
            activeRequest = request
            ActivityCompat.requestPermissions(activity, names, REQUEST_CODE)
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode != REQUEST_CODE) {
            return false
        }
        val request = activeRequest ?: return true
        activeRequest = null
        // An interrupted request reports empty arrays. The user made no choice,
        // so it must not count towards a permanent denial.
        val status =
            if (permissions.isEmpty()) {
                currentStatus(request.permission)
            } else {
                resolveRequestResult(request)
            }
        request.result.success(status)
        startNextRequest()
        return true
    }

    /**
     * Grant state read back after the dialog. Location counts as granted with
     * coarse access alone, as permission_handler reported it.
     */
    private fun resolveRequestResult(request: PermissionRequest): String {
        val activity = activityBinding?.activity
            ?: return currentStatus(request.permission)
        val names = request.permission.manifestNames
        if (names.any { isGranted(activity, it) }) {
            names.filter { isGranted(activity, it) }.forEach { clearDeniedBefore(activity, it) }
            return STATUS_GRANTED
        }
        var permanentlyDenied = false
        names.forEachIndexed { index, name ->
            if (isPermanentlyDenied(activity, name, request.rationaleBefore[index])) {
                permanentlyDenied = true
            }
        }
        return if (permanentlyDenied) STATUS_PERMANENTLY_DENIED else STATUS_DENIED
    }

    /**
     * Tells "ask again" from "only Settings can grant it" after a denial.
     * `shouldShowRequestPermissionRationale` is true once the user has denied
     * the dialog and Android will still show it. It goes back to false both
     * when the denial becomes permanent and when the user only dismissed the
     * first dialog, so the rationale state from before the request and a
     * persisted "denied before" flag separate those cases.
     */
    private fun isPermanentlyDenied(
        activity: Activity,
        name: String,
        rationaleBefore: Boolean,
    ): Boolean {
        if (ActivityCompat.shouldShowRequestPermissionRationale(activity, name)) {
            // Denied, and Android will show the dialog again next time.
            markDeniedBefore(activity, name)
            return false
        }
        if (rationaleBefore) {
            // Denied a second time (or "Don't ask again" on Android 10 and older).
            markDeniedBefore(activity, name)
            return true
        }
        // Answered without a dialog after an earlier denial, or the user
        // dismissed the very first dialog without choosing.
        return wasDeniedBefore(activity, name)
    }

    private fun currentStatus(permission: AppPermission): String {
        val context = activityBinding?.activity ?: applicationContext ?: return STATUS_DENIED
        return if (permission.manifestNames.any { isGranted(context, it) }) {
            STATUS_GRANTED
        } else {
            STATUS_DENIED
        }
    }

    /** The current activity when it is visible, so a dialog can appear. */
    private fun promptableActivity(): Activity? {
        val activity = activityBinding?.activity ?: return null
        val lifecycle = (activity as? LifecycleOwner)?.lifecycle ?: return activity
        return activity.takeIf { lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED) }
    }

    private fun isGranted(context: Context, name: String): Boolean =
        ContextCompat.checkSelfPermission(context, name) == PackageManager.PERMISSION_GRANTED

    private fun wasDeniedBefore(context: Context, name: String): Boolean =
        context.getSharedPreferences(name, Context.MODE_PRIVATE)
            .getBoolean(DENIED_BEFORE_KEY, false)

    private fun markDeniedBefore(context: Context, name: String) {
        context.getSharedPreferences(name, Context.MODE_PRIVATE)
            .edit()
            .putBoolean(DENIED_BEFORE_KEY, true)
            .apply()
    }

    /**
     * A grant starts tracking afresh, so a later "Ask every time" reset does
     * not turn the next dismissed dialog into a permanent denial.
     */
    private fun clearDeniedBefore(context: Context, name: String) {
        val preferences = context.getSharedPreferences(name, Context.MODE_PRIVATE)
        if (preferences.contains(DENIED_BEFORE_KEY)) {
            preferences.edit().remove(DENIED_BEFORE_KEY).apply()
        }
    }

    private fun openAppSettings(): Boolean {
        val context = activityBinding?.activity ?: applicationContext ?: return false
        val intent =
            Intent(
                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                Uri.fromParts("package", context.packageName, null),
            ).addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_NO_HISTORY or
                    Intent.FLAG_ACTIVITY_EXCLUDE_FROM_RECENTS,
            )
        return try {
            context.startActivity(intent)
            true
        } catch (error: ActivityNotFoundException) {
            Log.w(TAG, "App settings activity missing", error)
            false
        }
    }
}
