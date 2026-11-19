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
        private const val EVENT_ALERT_CHANNEL_ID = "stellar_wanted_event_alert_v2"
        const val EXTRA_CHALLENGE_ID = "ecc.stellar.app.WANTED_CHALLENGE_ID"
        const val EXTRA_RESULT_RECEIVER =
            "ecc.stellar.app.WANTED_MODE_RESULT_RECEIVER"
    }

    private lateinit var eventMonitor: WantedModeEventMonitor

    @Volatile
    private var corruptionDetected = false

    private val deadlineHandler = Handler(Looper.getMainLooper())
    private var previouslyPendingIds: Set<String> = emptySet()
    private var lastAlertFingerprint: String? = null

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

                val expired = store.getExpired()

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

                val pending = store.getPending()
                val newlyExpired = expired.any {
                    it.id in previouslyPendingIds && !it.recoveredFromReboot
                }
                previouslyPendingIds = pending.map { it.id }.toSet()

                // USB host device attachment is an Activity intent, not a
                // dependable runtime broadcast. Poll the host device set.
                eventMonitor.scanUsbHostDevices()

                val notificationManager =
                    getSystemService(NotificationManager::class.java)

                if (pending.isNotEmpty()) {
                    val fingerprint = pending.joinToString("|") { it.id }
                    if (lastAlertFingerprint != fingerprint) {
                        notificationManager.notify(
                            POWER_ALERT_NOTIFICATION_ID,
                            buildEventAlertNotification(pending.first(), pending.size)
                        )
                        lastAlertFingerprint = fingerprint
                    }
                } else {
                    notificationManager.cancel(POWER_ALERT_NOTIFICATION_ID)
                    lastAlertFingerprint = null
                }

                if (expired.isNotEmpty()) {
                    if (
                        newlyExpired &&
                        canShowEventAlerts() &&
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
                        buildNotification(expired.size)
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

    private fun canShowEventAlerts(): Boolean = try {
        val manager = getSystemService(NotificationManager::class.java)
        manager.areNotificationsEnabled() &&
            (Build.VERSION.SDK_INT < Build.VERSION_CODES.O ||
                (manager.getNotificationChannel(EVENT_ALERT_CHANNEL_ID)
                    ?.importance ?: NotificationManager.IMPORTANCE_NONE) >
                    NotificationManager.IMPORTANCE_NONE)
    } catch (_: Exception) {
        false
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
            if (!WantedModeWipeState.isEnabled(applicationContext)) {
                receiver?.send(android.app.Activity.RESULT_CANCELED, Bundle())
                stopSelf(startId)
                return START_NOT_STICKY
            }
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

            // Historical expirations are shown for review. A service/process
            // restart must not convert them into a new destructive trigger.
            val expiredAtStartup = eventMonitorChallengeStore()
                .getExpired()
                .size

            if (expiredAtStartup > 0) {
                val manager =
                    getSystemService(NotificationManager::class.java)
                manager.notify(
                    NOTIFICATION_ID,
                    buildNotification(expiredAtStartup)
                )
            }

            previouslyPendingIds = emptySet()
            lastAlertFingerprint = null
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

            manager.createNotificationChannel(
                NotificationChannel(
                    EVENT_ALERT_CHANNEL_ID,
                    "Wanted Mode – event verification",
                    NotificationManager.IMPORTANCE_HIGH
                ).apply {
                    description = "PIN verification for USB, Bluetooth, Wi-Fi, battery and power events"
                    setShowBadge(true)
                }
            )
        }
    }

    private fun buildEventAlertNotification(
        challenge: WantedModeChallengeStore.Challenge,
        pendingCount: Int
    ): Notification {
        val launchIntent = Intent(this, MainActivity::class.java).apply {
            action = "ecc.stellar.app.OPEN_WANTED_SECURITY"
            putExtra(EXTRA_CHALLENGE_ID, challenge.id)
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
            Notification.Builder(this, EVENT_ALERT_CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
                .setPriority(Notification.PRIORITY_HIGH)
        }

        val eventDescription = if (challenge.category == "BATTERY") {
            "Батеријата е под 20%"
        } else {
            "${challenge.category} ${challenge.action}"
        }
        val eventSummary = if (pendingCount > 1) {
            "$eventDescription (+${pendingCount - 1}) – отвори веднаш."
        } else {
            "$eventDescription – отвори веднаш за PIN-проверка."
        }

        return builder
            .setSmallIcon(android.R.drawable.ic_lock_lock)
            .setContentTitle("Stellar ECC – Wanted Mode PIN check")
            .setContentText(eventSummary)
            .setCategory(Notification.CATEGORY_EVENT)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .setAutoCancel(false)
            .setOngoing(true)
            .setOnlyAlertOnce(false)
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
        getSystemService(NotificationManager::class.java)
            .cancel(POWER_ALERT_NOTIFICATION_ID)

        if (::eventMonitor.isInitialized) {
            eventMonitor.releaseListeners()
        }
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
