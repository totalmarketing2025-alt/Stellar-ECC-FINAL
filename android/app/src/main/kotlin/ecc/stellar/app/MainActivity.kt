package ecc.stellar.app

import android.content.Intent
import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ResultReceiver
import android.os.Bundle
import android.content.Context
import android.view.WindowManager
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {

    companion object {
        private const val CHANNEL = "ecc.stellar.app/calls"
        private const val WANTED_MODE_CHANNEL = "ecc.stellar.app/wanted_mode_monitor"
        private const val CALL_ACTION = "ecc.stellar.app.CALL_ACTION"
        private const val METHOD_INCOMING_ACTION = "incomingCallAction"
        private const val METHOD_SET_CALL_ACTION_HANDLER_READY = "setCallActionHandlerReady"
        private const val METHOD_SET_CALL_ACTIVE = "setCallActive"
        private const val METHOD_SET_CALL_ENDED = "setCallEnded"

        private const val PREFS_NAME = "stellar_call_state"
        private const val PREF_PENDING_ACTION = "pending_call_action"
    }

    private var callChannel: MethodChannel? = null
    private lateinit var wantedModeEventMonitor: WantedModeEventMonitor
    private lateinit var wantedModeChallengeStore: WantedModeChallengeStore
    private var callActionHandlerReady = false

    // WANTED_PERMISSION_REQUEST
    private val wantedPermissionRequestCode = 7303
    private var pendingWantedModeResult: MethodChannel.Result? = null
    private val wantedModeStartupHandler = Handler(Looper.getMainLooper())
    private var wantedModeStartupTimeout: Runnable? = null



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
        callActionHandlerReady = false

        callChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL
        ).also { channel ->
            channel.setMethodCallHandler { call: MethodCall, result ->
                when (call.method) {
                    METHOD_SET_CALL_ACTION_HANDLER_READY -> {
                        val pending = takePendingCallAction()
                        callActionHandlerReady = true
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
                                    .setCallEnded(this@MainActivity, callId)
                            )
                        }
                    }

                    else -> result.notImplemented()
                }
            }
        }

        // WANTED_MODE_METHOD_CHANNEL_V1
        wantedModeEventMonitor = WantedModeEventMonitor.getInstance(applicationContext)
        wantedModeChallengeStore = WantedModeChallengeStore(applicationContext)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            WANTED_MODE_CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "startMonitoring" -> {
                    if (pendingWantedModeResult != null) {
                        result.error(
                            "WANTED_REQUEST_IN_PROGRESS",
                            "Wanted Mode permission or service startup is already pending.",
                            null
                        )
                    } else {
                        pendingWantedModeResult = result

                        if (
                            Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
                            checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) !=
                                PackageManager.PERMISSION_GRANTED
                        ) {
                            requestPermissions(
                                arrayOf(Manifest.permission.BLUETOOTH_CONNECT),
                                wantedPermissionRequestCode
                            )
                        } else {
                            startWantedModeService()
                        }
                    }
                }

                "stopMonitoring" -> {
                    val stopped = wantedModeEventMonitor.stop()
                    stopService(
                        Intent(
                            this@MainActivity,
                            WantedModeForegroundService::class.java
                        )
                    )
                    result.success(stopped)
                }

                "isMonitoringEnabled" ->
                    result.success(wantedModeEventMonitor.isEnabled())

                "getEvents" ->
                    result.success(wantedModeEventMonitor.readAudit())

                "isChallengeStoreCorrupted" ->
                    result.success(wantedModeChallengeStore.isCorrupted())

                "getPendingChallenges" -> {
                    val challenges = wantedModeChallengeStore.getPending().map {
                        mapOf(
                            "id" to it.id,
                            "category" to it.category,
                            "action" to it.action,
                            "createdAtMillis" to it.createdAtMillis,
                            "deadlineMillis" to it.deadlineMillis,
                            "expired" to it.expired
                        )
                    }
                    result.success(challenges)
                }

                "getExpiredChallenges" -> {
                    val challenges = wantedModeChallengeStore.getExpired().map {
                        mapOf(
                            "id" to it.id,
                            "category" to it.category,
                            "action" to it.action,
                            "createdAtMillis" to it.createdAtMillis,
                            "deadlineMillis" to it.deadlineMillis,
                            "expired" to it.expired
                        )
                    }
                    result.success(challenges)
                }

                "resolveChallenge" -> {
                    val id = call.argument<String>("id")
                    result.success(
                        id != null && wantedModeChallengeStore.resolve(id)
                    )
                }

                else -> result.notImplemented()
            }
        }

        deliverIntent(intent)
    }

    private fun startWantedModeService() {
        val methodResult = pendingWantedModeResult ?: return

        val receiver = object : ResultReceiver(Handler(Looper.getMainLooper())) {
            override fun onReceiveResult(
                resultCode: Int,
                resultData: Bundle?
            ) {
                if (pendingWantedModeResult !== methodResult) return

                wantedModeStartupTimeout?.let {
                    wantedModeStartupHandler.removeCallbacks(it)
                }
                wantedModeStartupTimeout = null
                pendingWantedModeResult = null

                if (resultCode == RESULT_OK) {
                    methodResult.success(true)
                } else {
                    methodResult.error(
                        "WANTED_MONITOR_START_FAILED",
                        resultData?.getString("error")
                            ?: "Foreground service could not start event monitoring.",
                        null
                    )
                }
            }
        }

        val timeout = Runnable {
            if (pendingWantedModeResult === methodResult) {
                pendingWantedModeResult = null
                wantedModeStartupTimeout = null

                // Fail closed: stop monitoring if startup was not confirmed.
                wantedModeEventMonitor.stop()
                stopService(
                    Intent(
                        this@MainActivity,
                        WantedModeForegroundService::class.java
                    )
                )

                methodResult.error(
                    "WANTED_SERVICE_START_TIMEOUT",
                    "Wanted Mode service did not confirm startup within 15 seconds.",
                    null
                )
            }
        }
        wantedModeStartupTimeout = timeout
        wantedModeStartupHandler.postDelayed(timeout, 15000)

        val serviceIntent = Intent(
            this,
            WantedModeForegroundService::class.java
        ).putExtra(
            WantedModeForegroundService.EXTRA_RESULT_RECEIVER,
            receiver
        )

        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(serviceIntent)
            } else {
                startService(serviceIntent)
            }
        } catch (error: Exception) {
            if (pendingWantedModeResult === methodResult) {
                wantedModeStartupTimeout?.let {
                    wantedModeStartupHandler.removeCallbacks(it)
                }
                wantedModeStartupTimeout = null
                pendingWantedModeResult = null
                methodResult.error(
                    "WANTED_SERVICE_START_FAILED",
                    error.message,
                    null
                )
            }
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(
            requestCode,
            permissions,
            grantResults
        )

        if (requestCode != wantedPermissionRequestCode) return

        if (grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        ) {
            startWantedModeService()
        } else {
            val pending = pendingWantedModeResult
            pendingWantedModeResult = null
            pending?.error(
                "BLUETOOTH_PERMISSION_DENIED",
                "Bluetooth permission is required to enable Wanted Mode monitoring.",
                null
            )
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        deliverIntent(intent)
    }

    private fun takePendingCallAction(): HashMap<String, Any?>? {
        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val pendingJson = prefs.getString(PREF_PENDING_ACTION, null) ?: return null

        return try {
            val pending = org.json.JSONObject(pendingJson)
            val payload = hashMapOf<String, Any?>(
                "action" to pending.optString("action", null),
                "callId" to pending.optString("callId", null),
                "remoteNickname" to pending.optString("remoteNickname", null),
                "kind" to pending.optString("kind", null),
                "chatId" to pending.optString("chatId", null)
            )
            prefs.edit().remove(PREF_PENDING_ACTION).apply()
            payload
        } catch (_: Throwable) {
            prefs.edit().remove(PREF_PENDING_ACTION).apply()
            null
        }
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

        val pendingJson = org.json.JSONObject().apply {
            put("action", payload["action"])
            put("callId", payload["callId"])
            put("remoteNickname", payload["remoteNickname"])
            put("kind", payload["kind"])
            put("chatId", payload["chatId"])
        }.toString()

        val channel = callChannel

        if (channel == null || !callActionHandlerReady) {
            getSharedPreferences(
                PREFS_NAME,
                Context.MODE_PRIVATE
            ).edit()
                .putString(PREF_PENDING_ACTION, pendingJson)
                .apply()
            return
        }

        channel.invokeMethod(
            METHOD_INCOMING_ACTION,
            payload
        )
    }
}
