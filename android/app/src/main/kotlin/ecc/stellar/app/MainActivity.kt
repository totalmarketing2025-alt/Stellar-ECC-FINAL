package ecc.stellar.app

import android.content.Intent
import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {

    companion object {
        private const val CHANNEL = "ecc.stellar.app/calls"
        private const val CALL_ACTION = "ecc.stellar.app.CALL_ACTION"
        private const val METHOD_INCOMING_ACTION = "incomingCallAction"
        private const val METHOD_GET_PENDING_ACTION = "getPendingCallAction"
        private const val METHOD_SET_CALL_ACTIVE = "setCallActive"
        private const val METHOD_SET_CALL_ENDED = "setCallEnded"
    }

    private var callChannel: MethodChannel? = null
    private var pendingCallAction: HashMap<String, Any?>? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        window.setFlags(
            WindowManager.LayoutParams.FLAG_SECURE,
            WindowManager.LayoutParams.FLAG_SECURE
        )
    }

    override fun configureFlutterEngine(
        flutterEngine: FlutterEngine
    ) {
        super.configureFlutterEngine(flutterEngine)

        callChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL
        ).also { channel ->
            channel.setMethodCallHandler { call: MethodCall, result ->
                when (call.method) {
                    METHOD_GET_PENDING_ACTION -> {
                        val pending = pendingCallAction
                        pendingCallAction = null
                        result.success(pending)
                    }

                    METHOD_SET_CALL_ACTIVE -> {
                        val callId = call.argument<String>("callId").orEmpty()
                        if (callId.isBlank()) {
                            result.success(false)
                        } else {
                            result.success(
                                ecc.stellar.app.calls.StellarCallManager
                                    .setCallActive(callId)
                            )
                        }
                    }

                    METHOD_SET_CALL_ENDED -> {
                        val callId = call.argument<String>("callId").orEmpty()
                        if (callId.isBlank()) {
                            result.success(false)
                        } else {
                            result.success(
                                ecc.stellar.app.calls.StellarCallManager
                                    .setCallEnded(callId)
                            )
                        }
                    }

                    else -> result.notImplemented()
                }
            }
        }

        deliverIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        deliverIntent(intent)
    }

    private fun deliverIntent(intent: Intent?) {
        if (intent?.action != CALL_ACTION) {
            return
        }

        val payload = hashMapOf<String, Any?>(
            "action" to intent.getStringExtra("callAction"),
            "callId" to intent.getStringExtra("stellar.call.id"),
            "remoteNickname" to intent.getStringExtra("stellar.call.remote"),
            "kind" to intent.getStringExtra("stellar.call.kind"),
            "chatId" to intent.getStringExtra("stellar.call.chat")
        )

        pendingCallAction = payload

        callChannel?.invokeMethod(
            METHOD_INCOMING_ACTION,
            payload
        )
    }
}
