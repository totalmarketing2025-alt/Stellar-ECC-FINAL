package ecc.stellar.app.calls

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

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

        when (intent.action) {
            StellarIncomingCallActivity.ACTION_REJECT -> {
                if (!StellarCallManager.rejectIncoming(callId)) {
                    Log.w("StellarCallAction", "Reject ignored: no active Telecom call")
                }
            }
            StellarIncomingCallActivity.ACTION_ANSWER -> {
                if (!StellarCallManager.answerIncoming(callId)) {
                    Log.w("StellarCallAction", "Answer ignored: no active Telecom call")
                }
            }
        }
    }
}
