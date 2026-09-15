package ecc.stellar.app

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.os.Build
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import ecc.stellar.app.calls.StellarCallManager

class StellarFirebaseMessagingService : FirebaseMessagingService() {

    companion object {
        private const val MESSAGE_CHANNEL = "stellar_messages"
        private const val MESSAGE_ID_BASE = 1001
    }

    override fun onMessageReceived(
        remoteMessage: RemoteMessage
    ) {
        super.onMessageReceived(remoteMessage)

        val data = remoteMessage.data

        if (data["type"] == "call") {
            handleIncomingCall(data)
            return
        }

        showGenericMessageNotification()
    }

    private fun handleIncomingCall(
        data: Map<String, String>
    ) {
        val callId = data["callId"].orEmpty()
        val remote = data["from"].orEmpty()
            .ifBlank { data["remoteNickname"].orEmpty() }

        val kind = data["kind"]
            ?.lowercase()
            ?: "voice"

        val chatId = data["chatId"]

        if (callId.isBlank() || remote.isBlank()) {
            return
        }

        if (kind != "voice" && kind != "video") {
            return
        }

        try {
            StellarCallManager.incoming(
                this,
                callId,
                remote,
                kind,
                chatId
            )
        } catch (_: Throwable) {
            // Do not crash the FCM service.
        }
    }

    private fun showGenericMessageNotification() {
        val manager =
            getSystemService(NOTIFICATION_SERVICE)
                as NotificationManager

        if (Build.VERSION.SDK_INT >= 26) {
            manager.createNotificationChannel(
                NotificationChannel(
                    MESSAGE_CHANNEL,
                    "Messages",
                    NotificationManager.IMPORTANCE_DEFAULT
                )
            )
        }

        val launch =
            packageManager.getLaunchIntentForPackage(packageName)

        val pending = launch?.let {
            PendingIntent.getActivity(
                this,
                0,
                it,
                PendingIntent.FLAG_UPDATE_CURRENT or
                    PendingIntent.FLAG_IMMUTABLE
            )
        }

        val builder =
            if (Build.VERSION.SDK_INT >= 26) {
                android.app.Notification.Builder(
                    this,
                    MESSAGE_CHANNEL
                )
            } else {
                @Suppress("DEPRECATION")
                android.app.Notification.Builder(this)
            }

        builder
            .setSmallIcon(
                ecc.stellar.app.R.drawable.ic_stat_stellar
            )
            .setContentTitle("Stellar ECC")
            .setContentText("Имате нова порака")
            .setAutoCancel(true)

        if (pending != null) {
            builder.setContentIntent(pending)
        }

        manager.notify(
            MESSAGE_ID_BASE +
                (System.currentTimeMillis() % 100000).toInt(),
            builder.build()
        )
    }

    override fun onNewToken(token: String) {
        super.onNewToken(token)
        // Token registration remains separate from call contents.
    }
}
