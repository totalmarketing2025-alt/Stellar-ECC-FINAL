package ecc.stellar.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.os.ResultReceiver
import android.os.IBinder
import android.os.Handler
import android.os.Looper

class WantedModeForegroundService : Service() {

    companion object {
        private const val CHANNEL_ID = "stellar_wanted_mode"
        private const val NOTIFICATION_ID = 7301
        private const val POWER_ALERT_CHANNEL_ID = "stellar_wanted_power_alert"
        private const val POWER_ALERT_NOTIFICATION_ID = 7305
        const val EXTRA_RESULT_RECEIVER =
            "ecc.stellar.app.WANTED_MODE_RESULT_RECEIVER"
    }

    private lateinit var eventMonitor: WantedModeEventMonitor

    @Volatile
    private var corruptionDetected = false

    private val deadlineHandler = Handler(Looper.getMainLooper())

    private val deadlineChecker = object : Runnable {
        override fun run() {
            try {
                if (WantedModeWipeState.hasPending(applicationContext)) {
                    eventMonitor.stop()
                    getSystemService(NotificationManager::class.java)
                        .notify(
                            NOTIFICATION_ID,
                            buildNotification(wipePending = true)
                        )
                    stopSelf()
                    return
                }

                val store = eventMonitorChallengeStore()

                if (store.isCorrupted()) {
                    corruptionDetected = true
                    eventMonitor.stop()

                    getSystemService(NotificationManager::class.java)
                        .notify(
                            NOTIFICATION_ID,
                            buildNotification(corrupted = true)
                        )
                    return
                }

                val expiredCount = store.getExpired()

                if (store.isCorrupted()) {
                    corruptionDetected = true
                    eventMonitor.stop()

                    getSystemService(NotificationManager::class.java)
                        .notify(
                            NOTIFICATION_ID,
                            buildNotification(corrupted = true)
                        )
                    return
                }

                val powerChallenge = store.getPending()
                    .firstOrNull { it.category == "POWER" }

                val notificationManager =
                    getSystemService(NotificationManager::class.java)

                if (powerChallenge != null) {
                    val remainingSeconds = (
                        (powerChallenge.deadlineMillis -
                            System.currentTimeMillis() + 999L) / 1000L
                    ).coerceAtLeast(0L)

                    notificationManager.notify(
                        POWER_ALERT_NOTIFICATION_ID,
                        buildPowerAlertNotification(remainingSeconds)
                    )
                } else {
                    notificationManager.cancel(POWER_ALERT_NOTIFICATION_ID)
                }

                if (expiredCount.isNotEmpty()) {
                    if (
                        WantedModeWipeState.isEnabled(applicationContext) &&
                        WantedModeWipeState.request(applicationContext)
                    ) {
                        eventMonitor.stop()

                        getSystemService(NotificationManager::class.java)
                            .notify(
                                NOTIFICATION_ID,
                                buildNotification(wipePending = true)
                            )

                        stopSelf()
                        return
                    }

                    val manager =
                        getSystemService(NotificationManager::class.java)
                    manager.notify(
                        NOTIFICATION_ID,
                        buildNotification(expiredCount.size)
                    )
                }
            } catch (_: Exception) {
                // Keep the foreground service alive; retry on next interval.
            }

            if (!corruptionDetected) {
                deadlineHandler.postDelayed(this, 1_000L)
            }
        }
    }

    private fun eventMonitorChallengeStore(): WantedModeChallengeStore {
        return WantedModeChallengeStore(applicationContext)
    }

    override fun onCreate() {
        super.onCreate()
        eventMonitor = WantedModeEventMonitor.getInstance(applicationContext)
        createNotificationChannel()
    }

    override fun onStartCommand(
        intent: Intent?,
        flags: Int,
        startId: Int
    ): Int {
        val receiver = getResultReceiver(intent)

        try {
            startForeground(NOTIFICATION_ID, buildNotification())

            val startupStore = eventMonitorChallengeStore()
            if (startupStore.isCorrupted()) {
                corruptionDetected = true
                eventMonitor.stop()

                getSystemService(NotificationManager::class.java)
                    .notify(
                        NOTIFICATION_ID,
                        buildNotification(corrupted = true)
                    )

                receiver?.send(
                    android.app.Activity.RESULT_CANCELED,
                    Bundle().apply {
                        putString(
                            "error",
                            "Wanted Mode challenge storage is corrupted. Monitoring was stopped."
                        )
                    }
                )
                return START_NOT_STICKY
            }

            // Recover expired deadlines after service/process restart.
            val expiredAtStartup = eventMonitorChallengeStore()
                .getExpired()
                .size

            if (
                expiredAtStartup > 0 &&
                WantedModeWipeState.isEnabled(applicationContext) &&
                WantedModeWipeState.request(applicationContext)
            ) {
                eventMonitor.stop()

                getSystemService(NotificationManager::class.java)
                    .notify(
                        NOTIFICATION_ID,
                        buildNotification(wipePending = true)
                    )

                receiver?.send(android.app.Activity.RESULT_OK, Bundle())
                stopSelf(startId)
                return START_NOT_STICKY
            }

            if (expiredAtStartup > 0) {
                val manager =
                    getSystemService(NotificationManager::class.java)
                manager.notify(
                    NOTIFICATION_ID,
                    buildNotification(expiredAtStartup)
                )
            }

            deadlineHandler.removeCallbacks(deadlineChecker)
            deadlineHandler.post(deadlineChecker)

            if (!eventMonitor.start()) {
                receiver?.send(
                    android.app.Activity.RESULT_CANCELED,
                    Bundle().apply {
                        putString(
                            "error",
                            "Wanted Mode event listeners could not be registered."
                        )
                    }
                )

                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                    stopForeground(STOP_FOREGROUND_REMOVE)
                } else {
                    @Suppress("DEPRECATION")
                    stopForeground(true)
                }

                stopSelf(startId)
                return START_NOT_STICKY
            }

            receiver?.send(android.app.Activity.RESULT_OK, Bundle())
        } catch (error: Exception) {
            receiver?.send(
                android.app.Activity.RESULT_CANCELED,
                Bundle().apply {
                    putString("error", error.message ?: "Service startup failed.")
                }
            )

            stopSelf(startId)
            return START_NOT_STICKY
        }

        return START_STICKY
    }

    @Suppress("DEPRECATION")
    private fun getResultReceiver(intent: Intent?): ResultReceiver? {
        if (intent == null) return null

        return if (Build.VERSION.SDK_INT >= 33) {
            intent.getParcelableExtra(
                EXTRA_RESULT_RECEIVER,
                ResultReceiver::class.java
            )
        } else {
            intent.getParcelableExtra(EXTRA_RESULT_RECEIVER)
        }
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Wanted Mode",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Известување додека е активен Wanted Mode"
                setShowBadge(false)
            }

            val manager =
                getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(channel)

            val powerAlertChannel = NotificationChannel(
                POWER_ALERT_CHANNEL_ID,
                "Wanted Mode – проверка на полнач",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "Итна PIN-проверка при приклучување полнач"
                setShowBadge(true)
            }
            manager.createNotificationChannel(powerAlertChannel)
        }
    }

    private fun buildPowerAlertNotification(
        remainingSeconds: Long
    ): Notification {
        val launchIntent = Intent(this, MainActivity::class.java).apply {
            action = "ecc.stellar.app.OPEN_WANTED_SECURITY"
            flags = Intent.FLAG_ACTIVITY_CLEAR_TOP or
                Intent.FLAG_ACTIVITY_SINGLE_TOP
        }

        val pendingIntent = PendingIntent.getActivity(
            this,
            7305,
            launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or
                PendingIntent.FLAG_IMMUTABLE
        )

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, POWER_ALERT_CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
                .setPriority(Notification.PRIORITY_HIGH)
        }

        return builder
            .setSmallIcon(android.R.drawable.ic_lock_lock)
            .setContentTitle("Stellar ECC – Wanted Mode")
            .setContentText(
                "Полначот е приклучен. Внеси PIN – преостануваат " +
                    "$remainingSeconds секунди."
            )
            .setCategory(Notification.CATEGORY_EVENT)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .setAutoCancel(false)
            .setOngoing(true)
            .setContentIntent(pendingIntent)
            .build()
    }

    private fun buildNotification(
        expiredCount: Int = 0,
        corrupted: Boolean = false,
        wipePending: Boolean = false
    ): Notification {
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)

        val pendingIntent = launchIntent?.let {
            PendingIntent.getActivity(
                this,
                7302,
                it,
                PendingIntent.FLAG_UPDATE_CURRENT or
                    PendingIntent.FLAG_IMMUTABLE
            )
        }

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }

        builder
            .setSmallIcon(android.R.drawable.ic_lock_lock)
            .setContentTitle("Stellar ECC")
            .setContentText(
                when {
                    wipePending ->
                        "Истечен е рокот. Отвори ја апликацијата за локално безбедносно бришење."

                    corrupted ->
                        "ГРЕШКА: складиштето за PIN-проверки е оштетено. Мониторингот е запрен."

                    expiredCount > 0 ->
                        "Истечени PIN-проверки: $expiredCount – отвори ја апликацијата."

                    else ->
                        "Wanted Mode е активен – мониторингот е вклучен."
                }
            )
            .setOngoing(true)
            .setCategory(Notification.CATEGORY_SERVICE)
            .setVisibility(Notification.VISIBILITY_PRIVATE)

        if (pendingIntent != null) {
            builder.setContentIntent(pendingIntent)
        }

        return builder.build()
    }

    override fun onDestroy() {
        deadlineHandler.removeCallbacks(deadlineChecker)

        if (::eventMonitor.isInitialized) {
            eventMonitor.releaseListeners()
        }
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
