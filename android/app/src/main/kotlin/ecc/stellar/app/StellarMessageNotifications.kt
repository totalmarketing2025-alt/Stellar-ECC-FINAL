package ecc.stellar.app

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.Color
import android.os.Build
import android.util.Log

/** Posts private, grouped message alerts without replacing earlier messages. */
object StellarMessageNotifications {

    private const val CHANNEL_ID = "stellar_messages"
    private const val GROUP_KEY = "ecc.stellar.app.MESSAGE_NOTIFICATIONS"
    private const val CHILD_NOTIFICATION_ID = 0
    private const val SUMMARY_NOTIFICATION_ID = 1001
    private const val SUMMARY_TAG = "stellar.message.summary"

    fun show(context: Context, wakeId: String) {
        val appContext = context.applicationContext
        val manager = appContext.getSystemService(Context.NOTIFICATION_SERVICE)
            as NotificationManager

        if (Build.VERSION.SDK_INT >= 33 &&
            appContext.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
                PackageManager.PERMISSION_GRANTED
        ) {
            Log.w("StellarFCM", "Message notification blocked: permission denied")
            return
        }

        if (Build.VERSION.SDK_INT >= 26) {
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    appContext.getString(R.string.notification_channel_messages),
                    NotificationManager.IMPORTANCE_DEFAULT,
                ).apply {
                    enableLights(true)
                    lightColor = Color.rgb(139, 92, 246)
                },
            )
        }

        val launch = appContext.packageManager
            .getLaunchIntentForPackage(appContext.packageName)
        val pending = launch?.let {
            PendingIntent.getActivity(
                appContext,
                0,
                it,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        }

        val notification = baseBuilder(appContext, pending)
            .setGroup(GROUP_KEY)
            .setGroupAlertBehavior(Notification.GROUP_ALERT_CHILDREN)
            .setOnlyAlertOnce(true)
            .build()

        // A unique server wake ID makes retries idempotent while keeping
        // notifications for distinct messages visible at the same time.
        manager.notify(notificationTag(wakeId), CHILD_NOTIFICATION_ID, notification)

        val summary = baseBuilder(appContext, pending)
            .setContentText(appContext.getString(R.string.notification_new_messages))
            .setGroup(GROUP_KEY)
            .setGroupSummary(true)
            .setGroupAlertBehavior(Notification.GROUP_ALERT_CHILDREN)
            .setOnlyAlertOnce(true)
            .build()
        manager.notify(SUMMARY_TAG, SUMMARY_NOTIFICATION_ID, summary)
    }

    private fun baseBuilder(
        context: Context,
        pending: PendingIntent?,
    ): Notification.Builder {
        val builder = if (Build.VERSION.SDK_INT >= 26) {
            Notification.Builder(context, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(context)
        }

        builder
            .setSmallIcon(R.drawable.ic_stat_stellar)
            .setContentTitle(context.getString(R.string.app_name))
            .setContentText(context.getString(R.string.notification_new_message))
            .setCategory(Notification.CATEGORY_MESSAGE)
            .setAutoCancel(true)

        if (pending != null) builder.setContentIntent(pending)
        return builder
    }

    private fun notificationTag(wakeId: String): String {
        val safeId = wakeId.filter { it.isLetterOrDigit() || it == '-' || it == '_' }
            .take(80)
            .ifEmpty { "unknown" }
        return "stellar.message.$safeId"
    }
}
