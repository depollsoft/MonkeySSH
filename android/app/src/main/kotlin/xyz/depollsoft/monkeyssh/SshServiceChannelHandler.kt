package xyz.depollsoft.monkeyssh

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.PowerManager
import android.provider.Settings
import android.util.Log
import androidx.lifecycle.Lifecycle
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.lang.ref.WeakReference

object SshServiceChannelHandler {
    private const val CHANNEL = "xyz.depollsoft.monkeyssh/ssh_service"
    private const val TAG = "SshServiceChannel"

    private var currentActivityRef = WeakReference<MainActivity>(null)
    private var methodChannel: MethodChannel? = null

    fun attachToEngine(flutterEngine: FlutterEngine, applicationContext: Context) {
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        if (methodChannel != null) {
            return
        }

        methodChannel = MethodChannel(messenger, CHANNEL).apply {
            setMethodCallHandler { call, result ->
                handleMethodCall(
                    call = call,
                    result = result,
                    applicationContext = applicationContext,
                )
            }
        }
    }

    fun attachActivity(activity: MainActivity) {
        currentActivityRef = WeakReference(activity)
    }

    fun detachActivity(activity: MainActivity) {
        if (currentActivityRef.get() === activity) {
            currentActivityRef.clear()
        }
    }

    private fun handleMethodCall(
        call: MethodCall,
        result: MethodChannel.Result,
        applicationContext: Context,
    ) {
        when (call.method) {
            "updateStatus" -> {
                val connectionCount = call.argument<Int>("connectionCount") ?: 0
                val connectedCount = call.argument<Int>("connectedCount") ?: 0
                if (connectionCount > 0) {
                    // Ask while visible, before the service needs to start in onPause.
                    resumedActivity()?.ensureNotificationPermission()
                }
                SshConnectionService.updateStatus(
                    context = applicationContext,
                    status = SshConnectionService.ConnectionStatus(
                        connectionCount = connectionCount,
                        connectedCount = connectedCount,
                    ),
                )
                result.success(null)
            }
            "setForegroundState" -> {
                // Native lifecycle owns visibility. Flutter reports inactive as
                // foreground and can deliver it after onPause started the service.
                // A delayed Dart message must not undo that native transition.
                SshConnectionService.refresh(applicationContext)
                result.success(null)
            }
            "stopService" -> {
                SshConnectionService.stop(applicationContext)
                result.success(null)
            }
            "isBatteryOptimizationIgnored" -> {
                result.success(isBatteryOptimizationIgnored(applicationContext))
            }
            "requestDisableBatteryOptimization" -> {
                result.success(requestDisableBatteryOptimization(applicationContext))
            }
            else -> result.notImplemented()
        }
    }

    private fun resumedActivity(): MainActivity? = currentActivityRef.get()?.takeIf {
        it.lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)
    }

    private fun isBatteryOptimizationIgnored(context: Context): Boolean {
        val powerManager =
            context.getSystemService(Context.POWER_SERVICE) as PowerManager
        return powerManager.isIgnoringBatteryOptimizations(context.packageName)
    }

    private fun requestDisableBatteryOptimization(context: Context): Boolean {
        if (isBatteryOptimizationIgnored(context)) {
            return true
        }

        val requestIntent = Intent(
            Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
            Uri.parse("package:${context.packageName}"),
        )
        if (launchSettingsIntent(context, requestIntent)) {
            return true
        }

        return launchSettingsIntent(
            context,
            Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS),
        )
    }

    private fun launchSettingsIntent(context: Context, intent: Intent): Boolean {
        val launchIntent = intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        if (launchIntent.resolveActivity(context.packageManager) == null) {
            return false
        }
        return try {
            context.startActivity(launchIntent)
            true
        } catch (error: SecurityException) {
            Log.w(TAG, "Battery optimization settings launch denied", error)
            false
        } catch (error: ActivityNotFoundException) {
            Log.w(TAG, "Battery optimization settings activity missing", error)
            false
        } catch (error: RuntimeException) {
            Log.w(TAG, "Battery optimization settings launch failed", error)
            false
        }
    }
}
