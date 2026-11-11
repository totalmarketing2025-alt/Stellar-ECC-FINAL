package ecc.stellar.app.calls

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import android.os.Handler
import android.os.Looper

/**
 * Receives notification actions without launching the PIN-protected UI.
 * Telecom owns native call state; Flutter remains the owner of WebRTC signaling.
 */
class StellarCallActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val callId = intent.getStringExtra(StellarCallManager.EXTRA_CALL_ID).orEmpty()
        if (callId.isBlank()) return
        val remote = intent.getStringExtra(StellarCallManager.EXTRA_REMOTE_NICKNAME).orEmpty()
        val kind = intent.getStringExtra(StellarCallManager.EXTRA_CALL_KIND) ?: "voice"
        val chatId = intent.getStringExtra(StellarCallManager.EXTRA_CHAT_ID)

        val action = intent.action
        if (action != StellarIncomingCallActivity.ACTION_ANSWER &&
            action != StellarIncomingCallActivity.ACTION_REJECT) return

        // Telecom may create its Connection after the notification is shown.
        // Keep the receiver alive while retrying briefly on the main thread.
        val pending = goAsync()
        val handler = Handler(Looper.getMainLooper())
        var attempts = 0
        fun attempt() {
            val handled = when (action) {
                StellarIncomingCallActivity.ACTION_ANSWER ->
                    StellarCallManager.answerIncoming(callId)
                else -> StellarCallManager.rejectIncoming(callId)
            }
            if (handled) {
                pending.finish()
                return
            }
            attempts++
            if (attempts < 12) {
                handler.postDelayed({ attempt() }, 150L)
            } else {
                Log.w("StellarCallAction", "Telecom connection unavailable for call action")
                // Do not fake an accepted call: without Telecom and live
                // signaling, opening the call UI would be misleading.
                pending.finish()
            }
        }
        handler.post { attempt() }
    }
}
