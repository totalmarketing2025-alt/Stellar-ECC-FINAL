package ecc.stellar.app.calls

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.os.Build
import android.content.Intent
import android.provider.Settings

object StellarIncomingCallNotification {

    private const val CHANNEL_ID = "stellar_incoming_calls"

    private fun id(callId: String): Int =
        200000 + kotlin.math.abs(callId.hashCode() % 100000)

    fun show(
        context: Context,
        callId: String,
        remoteNickname: String,
        kind: String
    ) {
        val manager =
            context.getSystemService(Context.NOTIFICATION_SERVICE)
                as NotificationManager

        if (Build.VERSION.SDK_INT >= 26) {
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    "Incoming calls",
                    NotificationManager.IMPORTANCE_HIGH
                ).apply {
                    description = "Stellar encrypted incoming calls"
                    setSound(
                        Settings.System.DEFAULT_RINGTONE_URI,
                        android.media.AudioAttributes.Builder()
                            .setUsage(
                                android.media.AudioAttributes.USAGE_NOTIFICATION_RINGTONE
                            )
                            .build()
                    )
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
        }

        val answer = Intent(
            context,
            StellarIncomingCallActivity::class.java
        ).apply {
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
                        "Stellar ECC"
                    } else {
                        remoteNickname
                    }
                )
                .setContentText(
                    if (kind == "video") {
                        "Incoming video call"
                    } else {
                        "Incoming call"
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
                .addAction(
                    android.app.Notification.Action.Builder(
                        null,
                        "Answer",
                        answerPending
                    ).build()
                )
                .addAction(
                    android.app.Notification.Action.Builder(
                        null,
                        "Decline",
                        rejectPending
                    ).build()
                )

        if (Build.VERSION.SDK_INT >= 31) {
            builder.setStyle(
                android.app.Notification.CallStyle.forIncomingCall(
                    android.app.Person.Builder()
                        .setName(
                            if (remoteNickname.isBlank()) {
                                "Stellar ECC"
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
