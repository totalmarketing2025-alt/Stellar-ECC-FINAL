package ecc.stellar.app

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log

import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import ecc.stellar.app.calls.StellarCallManager
import ecc.stellar.app.calls.StellarIncomingCallNotification

class StellarFirebaseMessagingService : FirebaseMessagingService() {

    companion object {
        private const val MESSAGE_CHANNEL = "stellar_messages"
        private const val MESSAGE_ID_BASE = 1001

        private const val BACKGROUND_CHANNEL =
            "ecc.stellar.app/push_background"

        private const val BACKGROUND_TIMEOUT_SECONDS = 20L

        private val backgroundEngineLock = Any()
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

        if (data["wake"] == "1") {
            startBackgroundMessageSync()
            return
        }

        showGenericMessageNotification()
    }

    private fun startBackgroundMessageSync() {
        val latch = CountDownLatch(1)

        Handler(Looper.getMainLooper()).post {
            synchronized(backgroundEngineLock) {
                try {
                    val loader =
                        io.flutter.embedding.engine.loader.FlutterLoader()

                    loader.startInitialization(applicationContext)

                    loader.ensureInitializationComplete(
                        applicationContext,
                        null
                    )

                    val engine =
                        io.flutter.embedding.engine.FlutterEngine(
                            applicationContext
                        )

                    val channel =
                        io.flutter.plugin.common.MethodChannel(
                            engine.dartExecutor.binaryMessenger,
                            BACKGROUND_CHANNEL
                        )

                    channel.setMethodCallHandler { call, result ->
                        if (call.method == "backgroundComplete") {
                            result.success(true)
                            latch.countDown()

                            Handler(Looper.getMainLooper()).post {
                                try {
                                    engine.destroy()
                                } catch (error: Throwable) {
                                    Log.e(
                                        "StellarFCM",
                                        "Background engine destroy failed",
                                        error
                                    )
                                }
                            }
                        } else {
                            result.notImplemented()
                        }
                    }

                    engine.dartExecutor.executeDartEntrypoint(
                        io.flutter.embedding.engine.dart.DartExecutor.DartEntrypoint(
                            loader.findAppBundlePath(),
                            "stellarPushBackgroundMain"
                        )
                    )

                    Log.d(
                        "StellarFCM",
                        "FIX5-A headless Flutter engine started"
                    )
                } catch (error: Throwable) {
                    Log.e(
                        "StellarFCM",
                        "FIX5-A headless engine failed",
                        error
                    )

                    latch.countDown()
                }
            }
        }

        try {
            val completed = latch.await(
                BACKGROUND_TIMEOUT_SECONDS,
                TimeUnit.SECONDS
            )

            if (!completed) {
                Log.w(
                    "StellarFCM",
                    "FIX5-A background sync timeout"
                )
            }
        } catch (error: InterruptedException) {
            Thread.currentThread().interrupt()

            Log.e(
                "StellarFCM",
                "FIX5-A background sync interrupted",
                error
            )
        }
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
        } catch (error: Throwable) {
            // Telecom can reject an incoming call for platform/state reasons.
            // Keep the existing incoming-call notification as a fallback.
            try {
                StellarIncomingCallNotification.show(
                    this,
                    callId,
                    remote,
                    kind
                )
            } catch (_: Throwable) {
                // Do not crash the FCM service if notification setup also fails.
            }

            android.util.Log.e(
                "StellarFCM",
                "Telecom incoming call failed for $callId",
                error
            )
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
