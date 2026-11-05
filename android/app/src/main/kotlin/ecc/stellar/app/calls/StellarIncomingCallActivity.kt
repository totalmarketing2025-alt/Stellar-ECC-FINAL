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
import ecc.stellar.app.R

class StellarIncomingCallActivity : Activity() {

    companion object {
        const val ACTION_INCOMING = "ecc.stellar.app.calls.INCOMING"
        const val ACTION_ANSWER = "ecc.stellar.app.calls.ANSWER"
        const val ACTION_REJECT = "ecc.stellar.app.calls.REJECT"
        const val ACTION_END = "ecc.stellar.app.calls.END"

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
                this.action = when (action) {
                    "answer" -> ACTION_ANSWER
                    "reject" -> ACTION_REJECT
                    "end" -> ACTION_END
                    else -> action
                }
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

            ACTION_END -> {
                forwardAction("end", callId, remote, kind, chatId)
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
        val blue = Color.rgb(74, 124, 255)
        val purple = Color.rgb(139, 92, 246)
        val success = Color.rgb(52, 211, 153)
        val danger = Color.rgb(248, 113, 113)
        val secondary = Color.rgb(139, 143, 163)

        fun dp(value: Int): Int =
            (value * resources.displayMetrics.density).toInt()

        val root = android.widget.FrameLayout(this)

        val wallpaper = android.widget.ImageView(this).apply {
            setImageResource(R.drawable.chat_background)
            scaleType = android.widget.ImageView.ScaleType.CENTER_CROP
            contentDescription = null
        }

        root.addView(
            wallpaper,
            android.widget.FrameLayout.LayoutParams(
                android.widget.FrameLayout.LayoutParams.MATCH_PARENT,
                android.widget.FrameLayout.LayoutParams.MATCH_PARENT
            )
        )

        val overlay = android.view.View(this).apply {
            setBackgroundColor(Color.argb(107, 0, 0, 0))
        }

        root.addView(
            overlay,
            android.widget.FrameLayout.LayoutParams(
                android.widget.FrameLayout.LayoutParams.MATCH_PARENT,
                android.widget.FrameLayout.LayoutParams.MATCH_PARENT
            )
        )

        val content = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            setPadding(dp(20), dp(48), dp(20), dp(32))
        }

        root.addView(
            content,
            android.widget.FrameLayout.LayoutParams(
                android.widget.FrameLayout.LayoutParams.MATCH_PARENT,
                android.widget.FrameLayout.LayoutParams.MATCH_PARENT
            )
        )

        val initial = remote.trim()
            .firstOrNull()
            ?.uppercaseChar()
            ?.toString() ?: "S"

        val avatar = TextView(this).apply {
            text = initial
            textSize = 48f
            setTextColor(Color.WHITE)
            typeface = Typeface.DEFAULT_BOLD
            gravity = Gravity.CENTER
            background = android.graphics.drawable.GradientDrawable(
                android.graphics.drawable.GradientDrawable.Orientation.TL_BR,
                intArrayOf(blue, purple)
            ).apply {
                shape = android.graphics.drawable.GradientDrawable.OVAL
            }
            contentDescription = "Contact avatar"
        }

        content.addView(
            avatar,
            LinearLayout.LayoutParams(dp(120), dp(120)).apply {
                bottomMargin = dp(24)
            }
        )

        val title = TextView(this).apply {
            text = remote.ifBlank { "Stellar ECC" }
            textSize = 22f
            setTextColor(Color.WHITE)
            typeface = Typeface.DEFAULT_BOLD
            gravity = Gravity.CENTER
        }

        content.addView(
            title,
            LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT
            )
        )

        val statusRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
        }

        val lock = TextView(this).apply {
            text = "🔒"
            textSize = 14f
        }

        val status = TextView(this).apply {
            text = "Ringing…"
            textSize = 14f
            setTextColor(secondary)
        }

        statusRow.addView(lock)

        statusRow.addView(
            status,
            LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT,
                LinearLayout.LayoutParams.WRAP_CONTENT
            ).apply {
                leftMargin = dp(6)
            }
        )

        content.addView(
            statusRow,
            LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT,
                LinearLayout.LayoutParams.WRAP_CONTENT
            ).apply {
                topMargin = dp(12)
            }
        )

        // Push the call controls to the bottom, like the Flutter call screen.
        content.addView(
            android.view.View(this),
            LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                0,
                1f
            )
        )

        fun createCallButton(
            label: String,
            color: Int,
            action: String,
        ): Button {
            return Button(this).apply {
                text = label
                textSize = 16f
                setTextColor(Color.WHITE)
                typeface = Typeface.DEFAULT_BOLD
                isAllCaps = false
                minHeight = dp(56)
                setPadding(dp(12), dp(8), dp(12), dp(8))
                background = android.graphics.drawable.GradientDrawable().apply {
                    shape = android.graphics.drawable.GradientDrawable.RECTANGLE
                    cornerRadius = dp(32).toFloat()
                    setColor(color)
                }

                setOnClickListener {
                    StellarIncomingCallNotification.cancel(
                        this@StellarIncomingCallActivity,
                        callId
                    )
                    forwardAction(action, callId, remote, kind, chatId)
                }
            }
        }

        val buttons = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
        }

        val answer = createCallButton("☎  Answer", success, "answer")
        val reject = createCallButton("✕  Decline", danger, "reject")

        buttons.addView(
            answer,
            LinearLayout.LayoutParams(0, dp(56), 1f).apply {
                rightMargin = dp(8)
            }
        )

        buttons.addView(
            reject,
            LinearLayout.LayoutParams(0, dp(56), 1f).apply {
                leftMargin = dp(8)
            }
        )

        content.addView(
            buttons,
            LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                dp(56)
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
