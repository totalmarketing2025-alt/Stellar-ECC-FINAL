package ecc.stellar.app.calls

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import ecc.stellar.app.R

/** Only called after Flutter has verified the invitation. */
internal object StellarGroupCallNotification {
    private const val CHANNEL = "stellar_group_calls"
    private const val ID = 3102

    fun show(context: Context, roomId: String) {
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= 26) {
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL, "Group calls", NotificationManager.IMPORTANCE_HIGH)
            )
        }
        val launch = context.packageManager.getLaunchIntentForPackage(context.packageName) ?: return
        val pending = PendingIntent.getActivity(context, 0, launch,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        fun actionIntent(action: String): PendingIntent {
            val intent = Intent(launch).apply {
                data = Uri.parse("stellar-group-action://invitation/$roomId/$action")
                putExtra("stellar.group.roomId", roomId)
                putExtra("stellar.group.action", action)
                addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            }
            return PendingIntent.getActivity(context, 0, intent,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        }
        @Suppress("DEPRECATION")
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(context, CHANNEL)
            else Notification.Builder(context)
        builder.setSmallIcon(R.drawable.ic_stat_stellar)
            .setContentTitle("Stellar ECC")
            .setContentText("Incoming group call — open to respond")
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .setCategory(Notification.CATEGORY_CALL)
            .setPriority(Notification.PRIORITY_HIGH)
            .setContentIntent(pending)
            .addAction(Notification.Action.Builder(
                android.graphics.drawable.Icon.createWithResource(context, android.R.drawable.ic_menu_call),
                "Join", actionIntent("join")
            ).build())
            .addAction(Notification.Action.Builder(
                android.graphics.drawable.Icon.createWithResource(context, android.R.drawable.ic_menu_close_clear_cancel),
                "Decline", actionIntent("decline")
            ).build())
            .setAutoCancel(true)
        if (Build.VERSION.SDK_INT >= 26) builder.setTimeoutAfter(45_000L)
        try {
            manager.notify(roomId, ID, builder.build())
        } catch (_: SecurityException) {
            // Notification permission may be denied; in-app invitation remains.
        }
    }

    fun cancel(context: Context, roomId: String) {
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.cancel(roomId, ID)
    }
}
