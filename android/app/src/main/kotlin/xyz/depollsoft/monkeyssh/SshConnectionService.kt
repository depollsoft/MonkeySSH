package xyz.depollsoft.monkeyssh

import android.app.ForegroundServiceStartNotAllowedException
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationCompat.BigTextStyle
import androidx.core.content.ContextCompat
import java.util.concurrent.Executors

/**
 * Shows a persistent notification and holds a wake lock while an SSH session
 * is active while the app is backgrounded.
 * startForeground must be the first thing onStartCommand does, even for stop
 * intents or revoked notification permission. Optional work follows promotion.
 */
class SshConnectionService : Service() {
    data class ConnectionStatus(
        val connectionCount: Int,
        val connectedCount: Int,
    )

    companion object {
        private const val TAG = "SshConnectionService"
        const val CHANNEL_ID = "ssh_connection"
        const val NOTIFICATION_ID = 1

        private const val ACTION_SYNC = "xyz.depollsoft.monkeyssh.action.SYNC"
        private const val ACTION_RESHOW_NOTIFICATION =
            "xyz.depollsoft.monkeyssh.action.RESHOW_NOTIFICATION"
        private const val ACTION_STOP = "xyz.depollsoft.monkeyssh.action.STOP"

        private var latestStatus: ConnectionStatus? = null
        private var isAppForeground = true

        // All lifecycle and method-channel state is confined to the main thread.
        private val mainHandler = Handler(Looper.getMainLooper())
        private var startRequested = false
        private var instance: SshConnectionService? = null
        private val notificationExecutor = Executors.newSingleThreadExecutor()
        private var isActivityVisible = false

        private fun onMain(action: () -> Unit) {
            if (Looper.myLooper() == Looper.getMainLooper()) {
                action()
            } else {
                mainHandler.post { action() }
            }
        }

        fun setActivityVisible(visible: Boolean) = onMain {
            isActivityVisible = visible
        }

        fun updateStatus(
            context: Context,
            status: ConnectionStatus,
        ) = onMain {
            latestStatus = status
            syncServiceState(context)
        }

        fun setForegroundState(
            context: Context,
            isForeground: Boolean,
        ) = onMain {
            isAppForeground = isForeground
            syncServiceState(context)
        }

        fun refresh(context: Context) = onMain {
            syncServiceState(context)
        }

        fun hasActiveConnections(): Boolean = (latestStatus?.connectionCount ?: 0) > 0

        fun stop(context: Context) = onMain {
            latestStatus = null
            stopServiceUnlessStarting(context)
        }

        /** The status to present, or null when the service must not run. */
        private fun presentableStatus(context: Context): ConnectionStatus? {
            val status = latestStatus ?: return null
            if (status.connectionCount <= 0 || isAppForeground) {
                return null
            }
            return status.takeIf { hasNotificationPermission(context) }
        }

        private fun syncServiceState(context: Context) {
            val status = presentableStatus(context)
            if (status == null) {
                stopServiceUnlessStarting(context)
                return
            }

            instance?.let {
                it.refreshPresentation()
                return
            }
            if (startRequested) return
            // Dart may deliver a status update long after onStop. Start during
            // the native onPause transition instead, while the activity is visible.
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && !isActivityVisible) {
                Log.w(TAG, "SSH foreground service start skipped: activity not visible")
                return
            }
            val intent = Intent(context, SshConnectionService::class.java).apply {
                action = ACTION_SYNC
            }
            startRequested = true
            try {
                ContextCompat.startForegroundService(context, intent)
            } catch (error: IllegalStateException) {
                // ForegroundServiceStartNotAllowedException is an IllegalStateException.
                // Android is authoritative if visibility changes during the request.
                startRequested = false
                Log.w(TAG, "SSH foreground service start skipped: ${error.javaClass.simpleName}")
            } catch (error: SecurityException) {
                startRequested = false
                Log.w(TAG, "SSH foreground service start denied")
            }
        }

        private fun stopServiceUnlessStarting(context: Context) {
            instance?.let {
                it.stopImmediately()
                return
            }
            // A queued first start must promote before it observes the stop state.
            if (!startRequested) {
                context.stopService(Intent(context, SshConnectionService::class.java))
            }
        }

        private fun hasNotificationPermission(context: Context): Boolean {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
                return true
            }
            return ContextCompat.checkSelfPermission(
                context,
                android.Manifest.permission.POST_NOTIFICATIONS,
            ) == android.content.pm.PackageManager.PERMISSION_GRANTED
        }
    }

    private var isPresenting = false
    private var wakeLock: PowerManager.WakeLock? = null

    private lateinit var startupNotification: Notification
    private var lastPresentedStatus: ConnectionStatus? = null
    private var presentationGeneration = 0

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        // No package lookup, PendingIntent binder calls, or Flutter startup on
        // the promotion path. Keep a valid notification if rich rendering fails.
        startupNotification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_notification_monkey)
            .setContentTitle("Keeping SSH connections alive")
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .build()
        if (promoteImmediately()) Companion.instance = this
    }

    private fun promoteImmediately(): Boolean {
        return try {
            startForeground(NOTIFICATION_ID, startupNotification)
            isPresenting = true
            true
        } catch (error: RuntimeException) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
                error is ForegroundServiceStartNotAllowedException
            ) {
                Log.w(TAG, "SSH foreground promotion denied by background restrictions")
                stopImmediately()
                false
            } else {
                throw error
            }
        }
    }

    override fun onStartCommand(
        intent: Intent?,
        flags: Int,
        startId: Int,
    ): Int {
        if (!promoteImmediately()) {
            Companion.startRequested = false
            return START_NOT_STICKY
        }
        Companion.instance = this
        lastPresentedStatus = null
        Companion.startRequested = false
        if (intent?.action == ACTION_STOP) {
            Companion.latestStatus = null
        }
        if (intent?.action == ACTION_RESHOW_NOTIFICATION) {
            Log.d(TAG, "Re-showing SSH foreground notification after dismissal")
        }

        // Companion state is newer than the queued intent. A connection can
        // close while startForegroundService is still delivering ACTION_SYNC.
        refreshPresentation()
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        if (Companion.instance === this) Companion.instance = null
        hidePresentation()
        super.onDestroy()
    }

    override fun onTimeout(startId: Int) {
        Log.w(TAG, "SSH foreground service timed out; stopping foreground service")
        stopAfterForegroundServiceTimeout()
    }

    override fun onTimeout(
        startId: Int,
        fgsType: Int,
    ) {
        Log.w(
            TAG,
            "SSH foreground service type timed out; stopping foreground service",
        )
        stopAfterForegroundServiceTimeout()
    }

    private fun stopAfterForegroundServiceTimeout() {
        Companion.latestStatus = null
        stopImmediately()
    }

    private fun stopImmediately() {
        // Remove foreground state and stop before wake-lock cleanup or any Dart work.
        stopForeground(STOP_FOREGROUND_REMOVE)
        isPresenting = false
        if (Companion.instance === this) Companion.instance = null
        stopSelf()
        hidePresentation()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun refreshPresentation() {
        val status = Companion.presentableStatus(this)
        if (status == null) {
            stopImmediately()
            return
        }

        // Status originates in the existing Dart engine. Never initialize an
        // engine or register plugins while handling service lifecycle callbacks.
        if (lastPresentedStatus != status) {
            lastPresentedStatus = status
            val generation = ++presentationGeneration
            notificationExecutor.execute {
                val notification = try {
                    buildNotification(status)
                } catch (error: RuntimeException) {
                    // Presentation is optional; keep the valid startup notification.
                    Log.w(TAG, "SSH notification rendering failed: ${error.javaClass.simpleName}")
                    startupNotification
                }
                mainHandler.post {
                    // A slow notification build must not resurrect a stopped service.
                    if (instance === this && isPresenting && presentationGeneration == generation) {
                        getSystemService(NotificationManager::class.java)
                            .notify(NOTIFICATION_ID, notification)
                    }
                }
            }
        }

        // Acquire a partial wake lock to keep the CPU running for SSH keepalives.
        if (wakeLock?.isHeld != true) {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock =
                pm
                    .newWakeLock(
                        PowerManager.PARTIAL_WAKE_LOCK,
                        "monkeyssh:ssh_background",
                    ).apply { acquire(24 * 60 * 60 * 1000L) }
        }
    }

    private fun buildNotification(status: ConnectionStatus): Notification {
        val tapIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val tapPendingIntent = PendingIntent.getActivity(
            this,
            0,
            tapIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val reShowNotificationIntent =
            PendingIntent.getService(
                this,
                1,
                Intent(this, SshConnectionService::class.java).apply {
                    action = ACTION_RESHOW_NOTIFICATION
                },
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )

        val title =
            if (status.connectionCount == 1) {
                "1 active SSH connection"
            } else {
                "${status.connectionCount} active SSH connections"
            }
        val summary =
            if (status.connectedCount == status.connectionCount) {
                "All sessions connected"
            } else {
                "${status.connectedCount}/${status.connectionCount} connected"
            }
        val detailText = "Keeping SSH connections alive in the background"

        val notification =
            NotificationCompat
                .Builder(this, CHANNEL_ID)
                .setContentTitle(title)
                .setContentText(summary)
                .setSmallIcon(R.drawable.ic_notification_monkey)
                .setOngoing(true)
                .setAutoCancel(false)
                .setOnlyAlertOnce(true)
                .setSilent(true)
                .setCategory(NotificationCompat.CATEGORY_SERVICE)
                .setPriority(NotificationCompat.PRIORITY_LOW)
                .setContentIntent(tapPendingIntent)
                .setDeleteIntent(reShowNotificationIntent)
                .setSubText(summary)
                .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
                .setStyle(
                    BigTextStyle()
                        .bigText(detailText)
                        .setSummaryText(summary),
                ).build()

        notification.flags =
            notification.flags or Notification.FLAG_ONGOING_EVENT or Notification.FLAG_NO_CLEAR
        return notification
    }

    private fun hidePresentation() {
        if (isPresenting) {
            stopForeground(STOP_FOREGROUND_REMOVE)
            isPresenting = false
        }
        lastPresentedStatus = null
        presentationGeneration++

        if (wakeLock?.isHeld == true) {
            wakeLock?.release()
        }
        wakeLock = null
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return
        }
        val channel =
            NotificationChannel(
                CHANNEL_ID,
                "SSH Connection",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "Shows when SSH sessions stay alive in the background"
                setShowBadge(false)
            }
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(channel)
    }
}
