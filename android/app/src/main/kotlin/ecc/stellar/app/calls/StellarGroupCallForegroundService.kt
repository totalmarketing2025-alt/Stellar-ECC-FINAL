package ecc.stellar.app.calls

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.app.PendingIntent
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import ecc.stellar.app.R

class StellarGroupCallForegroundService : Service() {
    private var activeRoom: String? = null

    companion object {
        const val START = "ecc.stellar.group.START"
        const val STOP = "ecc.stellar.group.STOP"
        const val ROOM = "roomId"
        const val VIDEO = "video"
        private const val CHANNEL = "stellar_active_group_calls"
        private const val ID = 42002
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val room = intent?.getStringExtra(ROOM)
        if (room == null || !Regex("[0-9a-f]{32}").matches(room)) {
            if (activeRoom == null) stopSelf(startId)
            return START_NOT_STICKY
        }
        when (intent.action) {
            STOP -> {
                if (activeRoom == room) {
                    activeRoom = null
                    stopForeground(STOP_FOREGROUND_REMOVE)
                    stopSelf(startId)
                } else if (activeRoom == null) stopSelf(startId)
            }
            START -> {
                if (activeRoom != null && activeRoom != room) return START_NOT_STICKY
                val video = intent.getBooleanExtra(VIDEO, false)
                if (Build.VERSION.SDK_INT >= 26) {
                    getSystemService(NotificationManager::class.java)
                        .createNotificationChannel(NotificationChannel(
                            CHANNEL, getString(R.string.notification_channel_active_group_calls), NotificationManager.IMPORTANCE_LOW
                        ))
                }
                val builder = NotificationCompat.Builder(this, CHANNEL)
                    .setSmallIcon(R.drawable.ic_stat_stellar)
                    .setContentTitle(getString(R.string.app_name))
                    .setContentText(getString(R.string.notification_group_call_in_progress))
                    .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
                    .setCategory(NotificationCompat.CATEGORY_CALL)
                    .setOngoing(true)
                    .setOnlyAlertOnce(true)
                packageManager.getLaunchIntentForPackage(packageName)?.let {
                    builder.setContentIntent(PendingIntent.getActivity(
                        this, ID, it, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
                    ))
                }
                try {
                    if (Build.VERSION.SDK_INT >= 30) {
                        val type = ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE or
                            (if (video) ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA else 0)
                        startForeground(ID, builder.build(), type)
                    } else {
                        startForeground(ID, builder.build())
                    }
                    activeRoom = room
                } catch (_: SecurityException) {
                    activeRoom = null
                    stopSelf(startId)
                }
            }
            else -> if (activeRoom == null) stopSelf(startId)
        }
        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
