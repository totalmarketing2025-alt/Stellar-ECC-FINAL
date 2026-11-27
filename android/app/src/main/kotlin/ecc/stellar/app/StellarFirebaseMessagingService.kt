package ecc.stellar.app

import android.util.Log
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager

import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import ecc.stellar.app.calls.StellarCallManager
import ecc.stellar.app.calls.StellarIncomingCallNotification

class StellarFirebaseMessagingService : FirebaseMessagingService() {
    override fun onMessageReceived(
        remoteMessage: RemoteMessage
    ) {
        super.onMessageReceived(remoteMessage)

        val data = remoteMessage.data

        Log.i("StellarFCM", "FCM-11 push received: type=" +
            (data["type"] ?: "message") + ", wake=" + (data["wake"] ?: "0"))

        if (data["type"] == "group-call") {
            val wake = StellarGroupCallWake.parse(data)
            if (wake == null) {
                Log.w("StellarFCM", "Invalid or expired group wake ignored")
                return
            }
            // Wake metadata is not an authenticated invitation. Never start
            // Telecom or capture media from this push. Reuse authenticated sync.
            scheduleBackgroundMessageSync()
            return
        }

        if (data["type"] == "call") {
            handleIncomingCall(data)
            return
        }

        if (data["wake"] == "1") {
            // The wake only starts authenticated sync. Flutter decrypts the
            // queued envelope and posts one notification for an actual chat
            // message; receipts and control envelopes stay silent.
            scheduleBackgroundMessageSync()
            return
        }

        // Older data-only wake payloads also need authenticated sync. Avoid a
        // generic notification here because we cannot identify its message.
        scheduleBackgroundMessageSync()
    }

    private fun scheduleBackgroundMessageSync() {
        try {
            val request =
                OneTimeWorkRequestBuilder<StellarPushSyncWorker>()
                    .build()

            WorkManager
                .getInstance(applicationContext)
                .enqueueUniqueWork(
                    "stellar-push-sync",
                    ExistingWorkPolicy.APPEND_OR_REPLACE,
                    request
                )

            Log.d(
                "StellarFCM",
                "FIX1 push sync scheduled"
            )
        } catch (error: Throwable) {
            Log.e(
                "StellarFCM",
                "FIX1 failed to schedule push sync",
                error
            )
        }
    }

    private fun handleIncomingCall(
        data: Map<String, String>
    ) {
        val wake = StellarCallWake.parse(data)
        if (wake == null) {
            Log.w("StellarFCM", "P2-A invalid incoming call wake ignored")
            return
        }
        val callId = wake.callId
        val remote = wake.remote
        val kind = wake.kind
        val chatId = wake.chatId

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
                    kind,
                    chatId
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

    override fun onNewToken(token: String) {
        super.onNewToken(token)

        if (token.isBlank()) {
            return
        }

        // FCM can rotate the registration token while Flutter is not
        // running. Wake the existing authenticated Flutter registration
        // path so Directory is updated with the new token.
        try {
            scheduleBackgroundMessageSync()

            Log.d(
                "StellarFCM",
                "FIX4 FCM token refresh queued for authenticated registration"
            )
        } catch (error: Throwable) {
            Log.e(
                "StellarFCM",
                "FIX4 failed to schedule token refresh registration",
                error
            )
        }
    }
}
