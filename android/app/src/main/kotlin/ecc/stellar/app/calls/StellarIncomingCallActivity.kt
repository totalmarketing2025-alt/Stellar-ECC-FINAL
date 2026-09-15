package ecc.stellar.app.calls

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.Typeface
import android.os.Bundle
import android.view.Gravity
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView

class StellarIncomingCallActivity : Activity() {

    companion object {
        const val ACTION_INCOMING = "ecc.stellar.app.calls.INCOMING"
        const val ACTION_ANSWER = "ecc.stellar.app.calls.ANSWER"
        const val ACTION_REJECT = "ecc.stellar.app.calls.REJECT"

        fun launchAction(
            context: Context,
            action: String,
            callId: String,
            remoteNickname: String,
            kind: String,
            chatId: String? = null,
        ) {
            val intent = Intent(
                context,
                StellarIncomingCallActivity::class.java
            ).apply {
                this.action = action
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
                    putExtra(StellarCallManager.EXTRA_CHAT_ID, chatId)
                }
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }

            context.startActivity(intent)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        if (android.os.Build.VERSION.SDK_INT >= 27) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        }

        val callId = intent.getStringExtra(
            StellarCallManager.EXTRA_CALL_ID
        ).orEmpty()

        val remote = intent.getStringExtra(
            StellarCallManager.EXTRA_REMOTE_NICKNAME
        ).orEmpty()

        val kind = intent.getStringExtra(
            StellarCallManager.EXTRA_CALL_KIND
        ) ?: "voice"

        val chatId = intent.getStringExtra(
            StellarCallManager.EXTRA_CHAT_ID
        )

        val action = intent.action

        when (action) {
            ACTION_ANSWER -> {
                forwardAction("answer", callId, remote, kind, chatId)
                return
            }

            ACTION_REJECT -> {
                forwardAction("reject", callId, remote, kind, chatId)
                return
            }

            ACTION_INCOMING -> {
                showIncomingCall(callId, remote, kind, chatId)
                return
            }

            else -> finish()
        }
    }

    private fun showIncomingCall(
        callId: String,
        remote: String,
        kind: String,
        chatId: String?,
    ) {
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setPadding(48, 80, 48, 80)
            setBackgroundColor(Color.BLACK)
        }

        val title = TextView(this).apply {
            text = if (remote.isBlank()) "Stellar ECC" else remote
            textSize = 30f
            setTextColor(Color.WHITE)
            setTypeface(Typeface.DEFAULT, Typeface.BOLD)
            gravity = Gravity.CENTER
        }

        val subtitle = TextView(this).apply {
            text = if (kind == "video") {
                "Incoming video call"
            } else {
                "Incoming call"
            }
            textSize = 20f
            setTextColor(Color.LTGRAY)
            gravity = Gravity.CENTER
            setPadding(0, 24, 0, 80)
        }

        val answer = Button(this).apply {
            text = if (kind == "video") "Answer video call" else "Answer"
            textSize = 18f
            setOnClickListener {
                StellarIncomingCallNotification.cancel(
                    this@StellarIncomingCallActivity,
                    callId
                )
                forwardAction("answer", callId, remote, kind, chatId)
            }
        }

        val reject = Button(this).apply {
            text = "Decline"
            textSize = 18f
            setOnClickListener {
                StellarIncomingCallNotification.cancel(
                    this@StellarIncomingCallActivity,
                    callId
                )
                forwardAction("reject", callId, remote, kind, chatId)
            }
        }

        root.addView(
            title,
            LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT
            )
        )

        root.addView(
            subtitle,
            LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT
            )
        )

        root.addView(
            answer,
            LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT
            ).apply {
                bottomMargin = 24
            }
        )

        root.addView(
            reject,
            LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT
            )
        )

        setContentView(root)
    }

    private fun forwardAction(
        action: String,
        callId: String,
        remote: String,
        kind: String,
        chatId: String? = null,
    ) {
        val launch = packageManager.getLaunchIntentForPackage(packageName)

        if (launch != null) {
            launch.action = "ecc.stellar.app.CALL_ACTION"
            launch.putExtra("callAction", action)
            launch.putExtra(
                StellarCallManager.EXTRA_CALL_ID,
                callId
            )
            launch.putExtra(
                StellarCallManager.EXTRA_REMOTE_NICKNAME,
                remote
            )
            launch.putExtra(
                StellarCallManager.EXTRA_CALL_KIND,
                kind
            )

            if (!chatId.isNullOrBlank()) {
                launch.putExtra(
                    StellarCallManager.EXTRA_CHAT_ID,
                    chatId,
                )
            }

            launch.addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP
            )

            startActivity(launch)
        }

        finish()
    }
}
