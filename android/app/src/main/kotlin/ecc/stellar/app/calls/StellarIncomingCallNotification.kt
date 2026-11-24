package ecc.stellar.app.calls

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.os.Build
import android.content.Intent

object StellarIncomingCallNotification {

    private const val CHANNEL_ID = "stellar_incoming_calls_v2"

    private fun id(callId: String): Int =
        200000 + kotlin.math.abs(callId.hashCode() % 100000)

    fun show(
        context: Context,
        callId: String,
        remoteNickname: String,
        kind: String,
        chatId: String?
    ) {
        val manager =
            context.getSystemService(Context.NOTIFICATION_SERVICE)
                as NotificationManager

        if (Build.VERSION.SDK_INT >= 26) {
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    context.getString(R.string.notification_channel_incoming_calls),
                    NotificationManager.IMPORTANCE_HIGH
                ).apply {
                    description = context.getString(R.string.notification_channel_incoming_calls_description)
                    setSound(null, null)
                }
            )
        }

        val fullScreen = Intent(
            context,
            StellarIncomingCallActivity::class.java
        ).apply {
            action = StellarIncomingCallActivity.ACTION_INCOMING
            putExtra(StellarCallManager.EXTRA_CALL_ID, callId)
            putExtra(
                StellarCallManager.EXTRA_REMOTE_NICKNAME,
                remoteNickname
            )
            putExtra(
                StellarCallManager.EXTRA_CALL_KIND,
                kind
            )
            if (!chatId.isNullOrBlank()) {
                putExtra(
                    StellarCallManager.EXTRA_CHAT_ID,
                    chatId
                )
            }
        }

        val answer = Intent(
            context,
            StellarIncomingCallActivity::class.java
        ).apply {
            // Notification action is a direct user gesture. Launching an Activity
            // here is allowed on modern Android, unlike starting one from a
            // background BroadcastReceiver or Telecom callback.
            action = StellarIncomingCallActivity.ACTION_ANSWER
            putExtra(StellarCallManager.EXTRA_CALL_ID, callId)
            putExtra(
                StellarCallManager.EXTRA_REMOTE_NICKNAME,
                remoteNickname
            )
            putExtra(
                StellarCallManager.EXTRA_CALL_KIND,
                kind
            )
            if (!chatId.isNullOrBlank()) {
                putExtra(
                    StellarCallManager.EXTRA_CHAT_ID,
                    chatId
                )
            }
        }

        val reject = Intent(
            context,
            StellarIncomingCallActivity::class.java
        ).apply {
            action = StellarIncomingCallActivity.ACTION_REJECT
            putExtra(StellarCallManager.EXTRA_CALL_ID, callId)
            putExtra(
                StellarCallManager.EXTRA_REMOTE_NICKNAME,
                remoteNickname
            )
            putExtra(
                StellarCallManager.EXTRA_CALL_KIND,
                kind
            )
            if (!chatId.isNullOrBlank()) {
                putExtra(
                    StellarCallManager.EXTRA_CHAT_ID,
                    chatId
                )
            }
        }

        val fullScreenPending = PendingIntent.getActivity(
            context,
            id(callId),
            fullScreen,
            PendingIntent.FLAG_UPDATE_CURRENT or
                PendingIntent.FLAG_IMMUTABLE
        )

        val answerPending = PendingIntent.getActivity(
            context,
            id(callId) + 1,
            answer,
            PendingIntent.FLAG_UPDATE_CURRENT or
                PendingIntent.FLAG_IMMUTABLE
        )

        val rejectPending = PendingIntent.getActivity(
            context,
            id(callId) + 2,
            reject,
            PendingIntent.FLAG_UPDATE_CURRENT or
                PendingIntent.FLAG_IMMUTABLE
        )

        val builder =
            android.app.Notification.Builder(context, CHANNEL_ID)
                .setSmallIcon(ecc.stellar.app.R.drawable.ic_stat_stellar)
                .setContentTitle(
                    if (remoteNickname.isBlank()) {
                        context.getString(R.string.app_name)
                    } else {
                        remoteNickname
                    }
                )
                .setContentText(
                    if (kind == "video") {
                        context.getString(R.string.notification_incoming_video_call)
                    } else {
                        context.getString(R.string.notification_incoming_voice_call)
                    }
                )
                .setCategory(
                    android.app.Notification.CATEGORY_CALL
                )
                .setOngoing(true)
                .setAutoCancel(false)
                .setFullScreenIntent(
                    fullScreenPending,
                    true
                )


        // CallStyle already provides Answer and Decline on Android 12+.
        // Add explicit actions only on older versions to avoid a third button.
        if (Build.VERSION.SDK_INT < 31) {
            builder.addAction(
                android.app.Notification.Action.Builder(null, context.getString(R.string.notification_answer), answerPending).build()
            ).addAction(
                android.app.Notification.Action.Builder(null, context.getString(R.string.notification_reject), rejectPending).build()
            )
        }

        if (Build.VERSION.SDK_INT >= 31) {
            builder.setStyle(
                android.app.Notification.CallStyle.forIncomingCall(
                    android.app.Person.Builder()
                        .setName(
                            if (remoteNickname.isBlank()) {
                                context.getString(R.string.app_name)
                            } else {
                                remoteNickname
                            }
                        )
                        .build(),
                    rejectPending,
                    answerPending
                )
            )
        }

        manager.notify(id(callId), builder.build())
    }

    fun cancel(context: Context, callId: String) {
        val manager =
            context.getSystemService(Context.NOTIFICATION_SERVICE)
                as NotificationManager

        manager.cancel(id(callId))
    }
}
