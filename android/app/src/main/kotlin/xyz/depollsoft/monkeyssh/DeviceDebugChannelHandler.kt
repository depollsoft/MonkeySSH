package xyz.depollsoft.monkeyssh

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.RemoteInput
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.net.Inet4Address
import java.net.InetAddress
import java.net.NetworkInterface
import java.net.SocketException
import java.util.ArrayDeque
import java.util.Collections

object DeviceDebugChannelHandler {
    private const val CHANNEL = "xyz.depollsoft.monkeyssh/device_debug"
    private const val TAG = "DeviceDebugChannel"
    private const val PAIRING_SERVICE_TYPE = "_adb-tls-pairing._tcp."
    private const val CONNECT_SERVICE_TYPE = "_adb-tls-connect._tcp."
    private const val PAIRING_CHANNEL_ID = "device_debug_pairing"
    private const val PAIRING_NOTIFICATION_ID = 2

    /// The "tap to return" prompt uses its own id so a late pairing-prompt
    /// cancellation cannot delete it.
    private const val RETURN_NOTIFICATION_ID = 3

    private const val SETTINGS_PACKAGE = "com.android.settings"

    /// Preference key of the Wireless debugging row in Developer options.
    private const val WIRELESS_DEBUGGING_PREFERENCE_KEY = "toggle_adb_wireless"

    /// Scrolls to and highlights a preference inside a Settings screen.
    private const val EXTRA_FRAGMENT_ARG_KEY = ":settings:fragment_args_key"
    private const val EXTRA_SHOW_FRAGMENT_ARGS = ":settings:show_fragment_args"

    /// Activities some builds expose for Wireless debugging. AOSP exports none,
    /// so these are attempted first and the Developer options screen is the
    /// fallback.
    private val WIRELESS_DEBUGGING_COMPONENTS = listOf(
        "com.android.settings.Settings\$WirelessDebuggingActivity",
        "com.android.settings.Settings\$AdbWirelessSettingsActivity",
    )

    /** Result key carrying the code typed into the notification reply field. */
    const val PAIRING_CODE_RESULT_KEY = "monkeyssh_pairing_code"

    /// Secure Wireless debugging (TLS pairing plus mDNS discovery) exists only
    /// from Android 11.
    private val isWirelessDebuggingSupported: Boolean
        get() = Build.VERSION.SDK_INT >= Build.VERSION_CODES.R

    private var methodChannel: MethodChannel? = null

    fun attachToEngine(flutterEngine: FlutterEngine, applicationContext: Context) {
        if (methodChannel != null) {
            return
        }

        methodChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL,
        ).apply {
            setMethodCallHandler { call, result ->
                handleMethodCall(
                    call = call,
                    result = result,
                    applicationContext = applicationContext,
                )
            }
        }
    }

    private fun handleMethodCall(
        call: MethodCall,
        result: MethodChannel.Result,
        applicationContext: Context,
    ) {
        when (call.method) {
            "isWirelessDebuggingSupported" -> result.success(
                isWirelessDebuggingSupported,
            )
            "showPairingCodePrompt" -> result.success(
                showPairingCodePrompt(
                    context = applicationContext,
                    status = call.argument<String>("status").orEmpty(),
                    busy = call.argument<Boolean>("busy") ?: false,
                ),
            )
            "hidePairingCodePrompt" -> {
                NotificationManagerCompat.from(applicationContext)
                    .cancel(PAIRING_NOTIFICATION_ID)
                result.success(null)
            }
            "hideReturnPrompt" -> {
                hideReturnPrompt(applicationContext)
                result.success(null)
            }
            "returnToApp" -> result.success(
                returnToApp(
                    context = applicationContext,
                    status = call.argument<String>("status").orEmpty(),
                ),
            )
            "openDeveloperOptions" -> result.success(
                openDeveloperOptions(applicationContext),
            )
            "discoverAdbEndpoint" -> {
                if (!isWirelessDebuggingSupported) {
                    result.error(
                        "unsupported_android_version",
                        "Wireless debugging requires Android 11 or newer",
                        null,
                    )
                    return
                }
                val serviceType = when (call.argument<String>("kind")) {
                    "pairing" -> PAIRING_SERVICE_TYPE
                    "connect" -> CONNECT_SERVICE_TYPE
                    else -> {
                        result.error(
                            "invalid_kind",
                            "ADB discovery kind must be pairing or connect",
                            null,
                        )
                        return
                    }
                }
                val timeoutMs = (
                    call.argument<Number>("timeoutMs")?.toLong() ?: 6000L
                ).coerceIn(1000L, 15000L)
                AdbEndpointDiscovery(
                    context = applicationContext,
                    serviceType = serviceType,
                    timeoutMs = timeoutMs,
                    result = result,
                ).start()
            }
            else -> result.notImplemented()
        }
    }

    /// Returns MonkeySSH to the foreground once pairing succeeds.
    ///
    /// Pairing runs while Android Settings is in front, so the app has to pull
    /// itself back afterwards. A direct `startActivity` from a notification
    /// reply is a notification trampoline, which Android 12+ blocks and which
    /// only ever had a ~10s grace window — shorter than pairing takes. Worse,
    /// a blocked background launch is usually dropped silently instead of
    /// throwing, so the direct attempt can never be trusted on its own.
    ///
    /// The tappable notification is therefore always posted, and MainActivity
    /// cancels it once the app really reaches the foreground.
    private fun returnToApp(context: Context, status: String): Boolean {
        val launchIntent = context.packageManager
            .getLaunchIntentForPackage(context.packageName)
            ?.apply {
                addFlags(
                    Intent.FLAG_ACTIVITY_NEW_TASK or
                        Intent.FLAG_ACTIVITY_REORDER_TO_FRONT or
                        Intent.FLAG_ACTIVITY_SINGLE_TOP,
                )
            }
        showReturnPrompt(context, status, launchIntent)
        if (launchIntent == null) {
            return false
        }
        return try {
            context.startActivity(launchIntent)
            true
        } catch (error: SecurityException) {
            Log.w(TAG, "Foreground return blocked; falling back to tap", error)
            false
        } catch (error: ActivityNotFoundException) {
            Log.w(TAG, "Foreground return activity missing", error)
            false
        }
    }

    /// Cancels the "tap to return" prompt.
    fun hideReturnPrompt(context: Context) {
        NotificationManagerCompat.from(context).cancel(RETURN_NOTIFICATION_ID)
    }

    /// Posts the tappable "return to MonkeySSH" notification.
    private fun showReturnPrompt(
        context: Context,
        status: String,
        launchIntent: Intent?,
    ) {
        val manager = NotificationManagerCompat.from(context)
        createPairingNotificationChannel(context)
        if (!manager.areNotificationsEnabled() || isPairingChannelBlocked(context)) {
            return
        }
        val contentIntent = launchIntent?.let {
            PendingIntent.getActivity(
                context,
                1,
                it,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        }
        val builder = NotificationCompat.Builder(context, PAIRING_CHANNEL_ID)
            .setContentTitle("Device debugging is ready")
            .setContentText(status)
            .setStyle(NotificationCompat.BigTextStyle().bigText(status))
            .setSmallIcon(R.drawable.ic_notification_monkey)
            .setCategory(NotificationCompat.CATEGORY_STATUS)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setOnlyAlertOnce(true)
            .setAutoCancel(true)
            .setContentIntent(contentIntent)
        try {
            manager.notify(RETURN_NOTIFICATION_ID, builder.build())
        } catch (error: SecurityException) {
            Log.w(TAG, "Return prompt notification denied", error)
        }
    }

    /// Posts (or updates) the reply notification used to collect the pairing
    /// code without leaving the Wireless debugging screen.
    ///
    /// Android cancels pairing as soon as Settings pauses, and the notification
    /// shade only takes window focus, so replying inline keeps pairing alive.
    private fun showPairingCodePrompt(
        context: Context,
        status: String,
        busy: Boolean,
    ): Boolean {
        val manager = NotificationManagerCompat.from(context)
        createPairingNotificationChannel(context)
        if (!manager.areNotificationsEnabled() || isPairingChannelBlocked(context)) {
            return false
        }

        val builder = NotificationCompat.Builder(context, PAIRING_CHANNEL_ID)
            .setContentTitle("Pair this device for debugging")
            .setContentText(status)
            .setStyle(NotificationCompat.BigTextStyle().bigText(status))
            .setSmallIcon(R.drawable.ic_notification_monkey)
            .setCategory(NotificationCompat.CATEGORY_STATUS)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setOnlyAlertOnce(true)
            .setOngoing(true)
            .setAutoCancel(false)

        if (busy) {
            builder.setProgress(0, 0, true)
        } else {
            val remoteInput = RemoteInput.Builder(PAIRING_CODE_RESULT_KEY)
                .setLabel("6-digit pairing code")
                .build()
            val replyIntent = Intent(context, DevicePairingCodeReceiver::class.java)
            val replyPendingIntent = PendingIntent.getBroadcast(
                context,
                0,
                replyIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE,
            )
            builder.addAction(
                NotificationCompat.Action.Builder(
                    R.drawable.ic_notification_monkey,
                    "Enter pairing code",
                    replyPendingIntent,
                )
                    .addRemoteInput(remoteInput)
                    .setAllowGeneratedReplies(false)
                    .build(),
            )
        }

        return try {
            manager.notify(PAIRING_NOTIFICATION_ID, builder.build())
            true
        } catch (error: SecurityException) {
            Log.w(TAG, "Pairing prompt notification denied", error)
            false
        }
    }

    /// Whether the user muted the pairing channel, which would post the prompt
    /// without ever showing it.
    private fun isPairingChannelBlocked(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return false
        }
        val channel = context.getSystemService(NotificationManager::class.java)
            ?.getNotificationChannel(PAIRING_CHANNEL_ID)
            ?: return false
        return channel.importance == NotificationManager.IMPORTANCE_NONE
    }

    private fun createPairingNotificationChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return
        }
        val channel = NotificationChannel(
            PAIRING_CHANNEL_ID,
            "Device debugging pairing",
            NotificationManager.IMPORTANCE_HIGH,
        ).apply {
            description = "Collects the Wireless debugging pairing code"
            setShowBadge(false)
        }
        context.getSystemService(NotificationManager::class.java)
            .createNotificationChannel(channel)
    }

    /// Routes a pairing code typed into the notification back to Dart.
    fun handleSubmittedPairingCode(context: Context, code: String) {
        // The reply can arrive while MonkeySSH is backgrounded, so make sure the
        // shared Flutter engine (and this channel) exists before delivering it.
        MonkeySshApplication.from(context).ensureSharedFlutterEngine()
        showPairingCodePrompt(
            context = context,
            status = "Pairing with the SSH host…",
            busy = true,
        )
        Handler(Looper.getMainLooper()).post {
            methodChannel?.invokeMethod("pairingCodeSubmitted", code)
        }
    }

    /// Opens the Wireless debugging screen, or the closest reachable screen.
    ///
    /// AOSP exports no Wireless debugging activity, so this tries the component
    /// names some builds do expose and otherwise falls back to Developer
    /// options with the Wireless debugging row highlighted and scrolled into
    /// view.
    private fun openDeveloperOptions(context: Context): Boolean {
        for (className in WIRELESS_DEBUGGING_COMPONENTS) {
            val direct = Intent()
                .setClassName(SETTINGS_PACKAGE, className)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            if (direct.resolveActivity(context.packageManager) != null &&
                launchSettingsIntent(context, direct)
            ) {
                return true
            }
        }

        val highlightArgs = Bundle().apply {
            putString(EXTRA_FRAGMENT_ARG_KEY, WIRELESS_DEBUGGING_PREFERENCE_KEY)
        }
        val developerOptions = Intent(Settings.ACTION_APPLICATION_DEVELOPMENT_SETTINGS)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            .putExtra(EXTRA_FRAGMENT_ARG_KEY, WIRELESS_DEBUGGING_PREFERENCE_KEY)
            .putExtra(EXTRA_SHOW_FRAGMENT_ARGS, highlightArgs)
        if (developerOptions.resolveActivity(context.packageManager) == null) {
            return false
        }
        return launchSettingsIntent(context, developerOptions)
    }

    private fun launchSettingsIntent(context: Context, intent: Intent): Boolean =
        try {
            context.startActivity(intent)
            true
        } catch (error: SecurityException) {
            Log.w(TAG, "Settings launch denied", error)
            false
        } catch (error: ActivityNotFoundException) {
            Log.w(TAG, "Settings activity missing", error)
            false
        }

    private class AdbEndpointDiscovery(
        context: Context,
        private val serviceType: String,
        private val timeoutMs: Long,
        private val result: MethodChannel.Result,
    ) {
        private val nsdManager =
            context.getSystemService(Context.NSD_SERVICE) as NsdManager
        private val mainHandler = Handler(Looper.getMainLooper())
        private val localAddresses = readLocalAddresses()
        private val pendingServices = ArrayDeque<NsdServiceInfo>()
        private val wifiManager =
            context.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        private var resolving = false
        private var completed = false
        private var multicastLock: WifiManager.MulticastLock? = null

        private val timeoutRunnable = Runnable { complete(null) }

        // NsdManager invokes listeners on its own thread. Every state change
        // and the single Flutter reply run on the main thread so the timeout
        // and a late resolution cannot race each other.
        private val discoveryListener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(registrationType: String) = Unit

            override fun onServiceFound(serviceInfo: NsdServiceInfo) {
                mainHandler.post {
                    pendingServices.add(serviceInfo)
                    resolveNext()
                }
            }

            override fun onServiceLost(serviceInfo: NsdServiceInfo) = Unit

            override fun onDiscoveryStopped(serviceType: String) = Unit

            override fun onStartDiscoveryFailed(
                serviceType: String,
                errorCode: Int,
            ) {
                mainHandler.post { fail("discovery_start_failed", errorCode) }
            }

            // Discovery is only stopped after completion, so there is no
            // pending result left to fail.
            override fun onStopDiscoveryFailed(
                serviceType: String,
                errorCode: Int,
            ) = Unit
        }

        fun start() {
            mainHandler.postDelayed(timeoutRunnable, timeoutMs)
            try {
                multicastLock = wifiManager.createMulticastLock(
                    "monkeyssh:wireless_adb_discovery",
                ).apply {
                    setReferenceCounted(false)
                    acquire()
                }
                nsdManager.discoverServices(
                    serviceType,
                    NsdManager.PROTOCOL_DNS_SD,
                    discoveryListener,
                )
            } catch (error: SecurityException) {
                completeError(
                    code = "discovery_permission_denied",
                    message = error.message ?: "ADB discovery permission was denied",
                )
            } catch (error: IllegalArgumentException) {
                completeError(
                    code = "discovery_unavailable",
                    message = error.message ?: "ADB discovery is unavailable",
                )
            }
        }

        private fun resolveNext() {
            if (completed || resolving || pendingServices.isEmpty()) {
                return
            }
            resolving = true
            val service = pendingServices.removeFirst()
            @Suppress("DEPRECATION")
            nsdManager.resolveService(
                service,
                object : NsdManager.ResolveListener {
                    override fun onResolveFailed(
                        serviceInfo: NsdServiceInfo,
                        errorCode: Int,
                    ) {
                        mainHandler.post {
                            resolving = false
                            resolveNext()
                        }
                    }

                    override fun onServiceResolved(serviceInfo: NsdServiceInfo) {
                        mainHandler.post {
                            resolving = false
                            onServiceResolvedOnMain(serviceInfo)
                        }
                    }
                },
            )
        }

        private fun onServiceResolvedOnMain(serviceInfo: NsdServiceInfo) {
            val address = resolvedAddresses(serviceInfo)
                .sortedBy { if (it is Inet4Address) 0 else 1 }
                .firstOrNull(::isLocalAddress)
            if (address != null && serviceInfo.port in 1..65535) {
                complete(
                    mapOf(
                        "serviceName" to serviceInfo.serviceName,
                        "host" to address.hostAddress,
                        "port" to serviceInfo.port,
                    ),
                )
                return
            }
            resolveNext()
        }

        private fun isLocalAddress(address: InetAddress): Boolean {
            if (address.isLoopbackAddress) {
                return true
            }
            return normalizeAddress(address.hostAddress) in localAddresses
        }

        private fun fail(code: String, errorCode: Int) {
            completeError(
                code = code,
                message = "ADB discovery failed with Android error $errorCode",
            )
        }

        private fun complete(endpoint: Map<String, Any>?) {
            if (completed) {
                return
            }
            completed = true
            cleanup()
            result.success(endpoint)
        }

        private fun completeError(code: String, message: String) {
            if (completed) {
                return
            }
            completed = true
            cleanup()
            result.error(code, message, null)
        }

        private fun cleanup() {
            mainHandler.removeCallbacks(timeoutRunnable)
            try {
                nsdManager.stopServiceDiscovery(discoveryListener)
            } catch (_: IllegalArgumentException) {
                // Android may already have stopped a failed discovery, or the
                // listener never registered because starting it threw.
            }
            multicastLock?.let { lock ->
                if (lock.isHeld) {
                    lock.release()
                }
            }
            multicastLock = null
        }

        private fun resolvedAddresses(serviceInfo: NsdServiceInfo): List<InetAddress> =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                serviceInfo.hostAddresses
            } else {
                @Suppress("DEPRECATION")
                listOfNotNull(serviceInfo.host)
            }

        private fun readLocalAddresses(): Set<String> {
            return try {
                buildSet {
                    val interfaces =
                        NetworkInterface.getNetworkInterfaces() ?: return@buildSet
                    for (networkInterface in Collections.list(interfaces)) {
                        for (address in Collections.list(networkInterface.inetAddresses)) {
                            if (!address.isLoopbackAddress) {
                                add(normalizeAddress(address.hostAddress))
                            }
                        }
                    }
                }
            } catch (error: SocketException) {
                Log.w(TAG, "Unable to enumerate local addresses", error)
                emptySet()
            }
        }

        private fun normalizeAddress(address: String): String =
            address.substringBefore('%').lowercase()
    }
}
