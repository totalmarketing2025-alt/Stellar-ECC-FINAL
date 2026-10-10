package ecc.stellar.app.calls

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import ecc.stellar.app.R

class StellarCallForegroundService : Service() {

    private var activeCallId: String? = null

    companion object {
        const val ACTION_START = "ecc.stellar.app.calls.START_FOREGROUND"
        const val ACTION_STOP = "ecc.stellar.app.calls.STOP_FOREGROUND"

        const val EXTRA_CALL_ID = "stellar.call.id"
        const val EXTRA_REMOTE_NICKNAME = "stellar.call.remote"
        const val EXTRA_CALL_KIND = "stellar.call.kind"

        private const val CHANNEL_ID = "stellar_active_calls"
        private const val NOTIFICATION_ID = 42001

        /**
         * Request a call-scoped stop. The service verifies the ID
         * before removing its foreground notification or stopping.
         */
        fun stopForCall(context: Context, callId: String) {
            if (callId.isBlank()) return

            val intent = Intent(
                context,
                StellarCallForegroundService::class.java,
            ).apply {
                action = ACTION_STOP
                putExtra(EXTRA_CALL_ID, callId)
            }

            context.startService(intent)
        }
    }

    override fun onCreate() {
        super.onCreate()
        createChannel()
    }

    override fun onStartCommand(
        intent: Intent?,
        flags: Int,
        startId: Int,
    ): Int {
        when (intent?.action) {
            ACTION_START -> {
                val incomingCallId =
                    intent.getStringExtra(EXTRA_CALL_ID).orEmpty()

                if (incomingCallId.isBlank()) {
                    stopSelf(startId)
                    return START_NOT_STICKY
                }

                activeCallId = incomingCallId

                val remote = intent.getStringExtra(EXTRA_REMOTE_NICKNAME)
                    .orEmpty()
                    .ifBlank { "Stellar call" }

                val kind = intent.getStringExtra(EXTRA_CALL_KIND)
                    .orEmpty()
                    .ifBlank { "voice" }

                startAsForeground(remote, kind)
            }

            ACTION_STOP -> {
                val requestedCallId =
                    intent.getStringExtra(EXTRA_CALL_ID).orEmpty()

                // A stale call must never stop a different call's service.
                if (requestedCallId.isNotBlank() &&
                    requestedCallId == activeCallId
                ) {
                    activeCallId = null
                    stopForeground(STOP_FOREGROUND_REMOVE)
                    stopSelf(startId)
                } else if (activeCallId == null) {
                    // ACTION_STOP may have started an otherwise idle service.
                    stopSelf(startId)
                }
            }
        }

        return START_NOT_STICKY
    }

    private fun startAsForeground(
        remoteNickname: String,
        kind: String,
    ) {
        val title =
            if (kind == "video") "Stellar video call"
            else "Stellar voice call"

        val notification = NotificationCompat.Builder(
            this,
            CHANNEL_ID,
        )
            .setSmallIcon(R.drawable.ic_stat_stellar)
            .setContentTitle(title)
            .setContentText(remoteNickname)
            .setOngoing(true)
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setOnlyAlertOnce(true)
            .build()

        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_PHONE_CALL,
            )
        } else {
            startForeground(
                NOTIFICATION_ID,
                notification,
            )
        }
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return
        }

        val manager =
            getSystemService(NotificationManager::class.java)

        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                "Active Stellar calls",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "Ongoing Stellar ECC calls"
            },
        )
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
