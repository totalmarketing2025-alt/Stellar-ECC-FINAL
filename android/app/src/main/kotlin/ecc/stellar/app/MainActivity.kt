package ecc.stellar.app

import android.content.Intent
import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ResultReceiver
import android.os.Bundle
import android.app.NotificationManager
import android.net.Uri
import android.provider.Settings
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
        private const val WANTED_NAVIGATION_CHANNEL = "ecc.stellar.app/wanted_mode_navigation"
        private const val EDGE_CHANNEL = "ecc.stellar.app/edge_lighting"
        private const val OPEN_WANTED_SECURITY_ACTION = "ecc.stellar.app.OPEN_WANTED_SECURITY"
        private const val WANTED_NAV_PREFS = "stellar_wanted_navigation"
        private const val PREF_PENDING_SECURITY_NAVIGATION = "pending_security_navigation"
        private const val PREF_PENDING_SECURITY_CHALLENGE_ID = "pending_security_challenge_id"
        private const val CALL_ACTION = "ecc.stellar.app.CALL_ACTION"
        private const val METHOD_INCOMING_ACTION = "incomingCallAction"
        private const val METHOD_SET_CALL_ACTION_HANDLER_READY = "setCallActionHandlerReady"
        private const val METHOD_SET_CALL_ACTIVE = "setCallActive"
        private const val METHOD_SET_CALL_ENDED = "setCallEnded"
        private const val METHOD_START_OUTGOING_RINGBACK = "startOutgoingRingback"
        private const val METHOD_STOP_CALL_RINGTONE = "stopCallRingtone"

        private const val PREFS_NAME = "stellar_call_state"
        private const val PREF_PENDING_ACTION = "pending_call_action"
        private const val STARTUP_PERMISSION_REQUEST_CODE = 7304
        private const val STARTUP_PERMISSION_PREFS = "stellar_startup_permissions"
        private const val PREF_STARTUP_PERMISSIONS_REQUESTED = "requested_v1"
        private const val PREF_FULL_SCREEN_SETTINGS_OPENED = "full_screen_settings_opened_v1"
    }

    private var groupChannel: MethodChannel? = null
    private val pendingGroupActions = linkedMapOf<String, Map<String, String>>()

    private var callChannel: MethodChannel? = null
    private lateinit var wantedModeEventMonitor: WantedModeEventMonitor
    private lateinit var wantedModeChallengeStore: WantedModeChallengeStore
    private var callActionHandlerReady = false
    private var pendingStartupPermissionResult: MethodChannel.Result? = null

    // WANTED_PERMISSION_REQUEST
    private val wantedPermissionRequestCode = 7303
    private var pendingWantedModeResult: MethodChannel.Result? = null
    private val wantedModeStartupHandler = Handler(Looper.getMainLooper())
    private var wantedModeStartupTimeout: Runnable? = null

    private lateinit var wantedModeChannel: MethodChannel
    private lateinit var wantedModeNavigationChannel: MethodChannel
    private val wantedWipePollHandler = Handler(Looper.getMainLooper())
    private var wantedWipeSignalSent = false

    private val wantedWipePoll: Runnable by lazy {
        object : Runnable {
            override fun run() {
                if (!WantedModeWipeState.hasPending(applicationContext)) {
                    wantedWipeSignalSent = false
                    wantedWipePollHandler.postDelayed(this, 500L)
                    return
                }

                if (!::wantedModeChannel.isInitialized || wantedWipeSignalSent) {
                    wantedWipePollHandler.postDelayed(this, 500L)
                    return
                }

                wantedWipeSignalSent = true
                wantedModeChannel.invokeMethod(
                    "wantedModeWipeRequested",
                    null,
                    object : MethodChannel.Result {
                        override fun success(result: Any?) {
                            // Flutter го извршува бришењето и потоа ја рестартира Activity.
                        }

                        override fun error(
                            errorCode: String,
                            errorMessage: String?,
                            errorDetails: Any?
                        ) {
                            wantedWipeSignalSent = false
                            wantedWipePollHandler.postDelayed(
                                wantedWipePoll,
                                500L
                            )
                        }

                        override fun notImplemented() {
                            wantedWipeSignalSent = false
                            wantedWipePollHandler.postDelayed(
                                wantedWipePoll,
                                500L
                            )
                        }
                    }
                )
            }
        }
    }

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
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "ecc.stellar.app/group_calls"
        ).also { groupChannel = it }.setMethodCallHandler { call, result ->
            val roomId = call.argument<String>("roomId").orEmpty()
            val manager = ecc.stellar.app.calls.StellarGroupCallManager
            when (call.method) {
                "startGroupForeground", "stopGroupForeground" -> {
                    if (!Regex("[0-9a-f]{32}").matches(roomId)) {
                        result.error("INVALID_GROUP_ROOM", "Invalid room ID", null)
                    } else {
                        val starting = call.method == "startGroupForeground"
                        val serviceIntent = Intent(
                            this@MainActivity,
                            ecc.stellar.app.calls.StellarGroupCallForegroundService::class.java
                        ).apply {
                            action = if (starting)
                                ecc.stellar.app.calls.StellarGroupCallForegroundService.START
                            else ecc.stellar.app.calls.StellarGroupCallForegroundService.STOP
                            putExtra(ecc.stellar.app.calls.StellarGroupCallForegroundService.ROOM, roomId)
                            putExtra(ecc.stellar.app.calls.StellarGroupCallForegroundService.VIDEO,
                                call.argument<Boolean>("video") == true)
                        }
                        try {
                            if (starting && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                startForegroundService(serviceIntent)
                            } else {
                                startService(serviceIntent)
                            }
                            // A successful dispatch is not confirmation of service startup.
                            result.success(true)
                        } catch (_: Exception) {
                            result.error("GROUP_FOREGROUND_DISPATCH_FAILED",
                                "Unable to dispatch group foreground service", null)
                        }
                    }
                }
                "takeGroupActions" -> {
                    val actions = pendingGroupActions.values.toList()
                    pendingGroupActions.clear()
                    result.success(actions)
                }
                "registerVerifiedInvitation" -> {
                    val registered = manager.registerVerifiedInvitation(roomId)
                    if (registered) {
                        ecc.stellar.app.calls.StellarGroupCallNotification.show(applicationContext, roomId)
                    }
                    result.success(registered)
                }
                "consumeInvitation" -> {
                    val consumed = manager.consumeInvitation(roomId)
                    ecc.stellar.app.calls.StellarGroupCallNotification.cancel(applicationContext, roomId)
                    result.success(consumed)
                }
                "dismissInvitation" -> {
                    manager.dismiss(roomId)
                    ecc.stellar.app.calls.StellarGroupCallNotification.cancel(applicationContext, roomId)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
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

                    METHOD_START_OUTGOING_RINGBACK -> {
                        val callId = call.argument<String>("callId").orEmpty()
                        if (callId.isBlank()) {
                            result.success(null)
                        } else {
                            ecc.stellar.app.calls.StellarCallAudio
                                .startOutgoingRingback(this@MainActivity, callId)
                            result.success(null)
                        }
                    }

                    METHOD_STOP_CALL_RINGTONE -> {
                        val callId = call.argument<String>("callId").orEmpty()
                        if (callId.isBlank()) {
                            result.success(null)
                        } else {
                            ecc.stellar.app.calls.StellarCallAudio.stop(callId)
                            result.success(null)
                        }
                    }

                    else -> result.notImplemented()
                }
            }
        }

        // WANTED_MODE_METHOD_CHANNEL_V1
        wantedModeEventMonitor = WantedModeEventMonitor.getInstance(applicationContext)
        wantedModeChallengeStore = WantedModeChallengeStore(applicationContext)

        wantedModeChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            WANTED_MODE_CHANNEL
        )

        wantedModeNavigationChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            WANTED_NAVIGATION_CHANNEL
        )

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            EDGE_CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "getState" -> result.success(
                    StellarEdgeLighting.state(applicationContext)
                )
                "setEnabled" -> {
                    val desired = call.argument<Boolean>("enabled") == true
                    result.success(
                        StellarEdgeLighting.setEnabled(applicationContext, desired)
                    )
                }
                "openPermissionSettings" -> {
                    if (!StellarEdgeLighting.supported()) {
                        result.success(false)
                    } else {
                        try {
                            startActivity(Intent(
                                Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                                Uri.parse("package:$packageName")
                            ))
                            result.success(true)
                        } catch (error: Throwable) {
                            result.error(
                                "EDGE_PERMISSION_SETTINGS_UNAVAILABLE",
                                "Cannot open Android overlay permission settings",
                                null
                            )
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }

        wantedModeChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "requestStartupPermissions" -> {
                    requestStartupPermissions(result)
                }

                "requestFullScreenCallAccess" -> {
                    requestFullScreenCallAccess(result)
                }

                "hasPendingLocalWipe" -> {
                    result.success(
                        WantedModeWipeState.hasPending(applicationContext)
                    )
                }

                // Flutter calls this only after Directory has verified a
                // revoked Guard identity with its old Signal key. Persist
                // the marker before the first destructive filesystem write;
                // the existing startup path retries interrupted wipes.
                "requestVerifiedGuardWipe" -> {
                    if (!WantedModeWipeState.request(applicationContext)) {
                        result.error(
                            "GUARD_WIPE_MARKER_FAILED",
                            "Unable to persist verified Guard wipe request.",
                            null
                        )
                    } else {
                        result.success(true)
                    }
                }

                "setWipeEnabled" -> {
                    val enabled = call.argument<Boolean>("enabled") == true
                    result.success(
                        WantedModeWipeState.setEnabled(
                            applicationContext,
                            enabled
                        )
                    )
                }

                "completeLocalWipe" -> {
                    val completed =
                        WantedModeWipeState.complete(applicationContext)

                    if (!completed) {
                        result.error(
                            "WIPE_PREFS_CLEAR_FAILED",
                            "Local preference cleanup did not complete.",
                            null
                        )
                    } else {
                        stopService(
                            Intent(
                                this@MainActivity,
                                WantedModeForegroundService::class.java
                            )
                        )

                        result.success(true)

                        wantedModeStartupHandler.postDelayed({
                            val launch = packageManager
                                .getLaunchIntentForPackage(packageName)

                            if (launch != null) {
                                launch.addFlags(
                                    Intent.FLAG_ACTIVITY_NEW_TASK or
                                        Intent.FLAG_ACTIVITY_CLEAR_TASK
                                )
                                startActivity(launch)
                            }
                        }, 150L)
                    }
                }

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

                "getMonitoringHealth" ->
                    result.success(wantedModeEventMonitor.getMonitoringHealth())

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
                            "remainingMillis" to wantedModeChallengeStore.remainingMillis(it),
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
                            "recoveredFromReboot" to it.recoveredFromReboot,
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

                "acknowledgeExpiredChallenge" -> {
                    val id = call.argument<String>("id")
                    result.success(
                        id != null && wantedModeChallengeStore.acknowledgeExpired(id)
                    )
                }

                "takePendingWantedSecurityNavigation" -> {
                    val prefs = getSharedPreferences(
                        WANTED_NAV_PREFS,
                        Context.MODE_PRIVATE
                    )
                    val pending = prefs.getBoolean(
                        PREF_PENDING_SECURITY_NAVIGATION,
                        false
                    )
                    val challengeId = prefs.getString(
                        PREF_PENDING_SECURITY_CHALLENGE_ID,
                        null
                    )
                    prefs.edit()
                        .remove(PREF_PENDING_SECURITY_NAVIGATION)
                        .remove(PREF_PENDING_SECURITY_CHALLENGE_ID)
                        .commit()
                    result.success(mapOf(
                        "pending" to pending,
                        "challengeId" to (challengeId ?: "")
                    ))
                }

                else -> result.notImplemented()
            }
        }

        deliverIntent(intent)
    }

    override fun onResume() {
        super.onResume()
        StellarEdgeLighting.setAppForeground(true)
        wantedWipePollHandler.removeCallbacks(wantedWipePoll)
        wantedWipePollHandler.post(wantedWipePoll)
    }

    override fun onPause() {
        StellarEdgeLighting.setAppForeground(false)
        wantedWipePollHandler.removeCallbacks(wantedWipePoll)
        wantedWipeSignalSent = false
        super.onPause()
    }

    private fun requestStartupPermissions(result: MethodChannel.Result) {
        val prefs = getSharedPreferences(
            STARTUP_PERMISSION_PREFS,
            Context.MODE_PRIVATE
        )

        // FCM-11: A previous request does not mean notifications are enabled.
        // Recheck the current Android permission state on every startup.
        // Keep the one-time behavior for unrelated camera/audio permissions.
        val previouslyRequested =
            prefs.getBoolean(PREF_STARTUP_PERMISSIONS_REQUESTED, false)
        if (previouslyRequested &&
            (Build.VERSION.SDK_INT < 33 ||
                checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
                    PackageManager.PERMISSION_GRANTED)
        ) {
            result.success(mapOf("alreadyRequested" to true))
            return
        }

        if (pendingStartupPermissionResult != null) {
            result.error(
                "STARTUP_PERMISSION_REQUEST_IN_PROGRESS",
                "Startup permission request is already running.",
                null
            )
            return
        }

        val required = mutableListOf(
            Manifest.permission.CAMERA,
            Manifest.permission.RECORD_AUDIO
        )

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            required.add(Manifest.permission.BLUETOOTH_CONNECT)
        }

        if (Build.VERSION.SDK_INT >= 33) {
            required.add(Manifest.permission.POST_NOTIFICATIONS)
        }

        val missing = required.filter {
            checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED &&
                (!previouslyRequested ||
                    it == Manifest.permission.POST_NOTIFICATIONS)
        }

        if (missing.isEmpty()) {
            prefs.edit()
                .putBoolean(PREF_STARTUP_PERMISSIONS_REQUESTED, true)
                .apply()
            result.success(mapOf("allAlreadyGranted" to true))
            return
        }

        pendingStartupPermissionResult = result

        try {
            requestPermissions(
                missing.toTypedArray(),
                STARTUP_PERMISSION_REQUEST_CODE
            )
        } catch (error: Exception) {
            pendingStartupPermissionResult = null
            result.error(
                "STARTUP_PERMISSION_REQUEST_FAILED",
                error.message,
                null
            )
        }
    }

    private fun requestFullScreenCallAccess(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < 34) {
            result.success(true)
            return
        }

        val manager = getSystemService(
            NotificationManager::class.java
        )

        if (manager.canUseFullScreenIntent()) {
            result.success(true)
            return
        }

        val prefs = getSharedPreferences(
            STARTUP_PERMISSION_PREFS,
            Context.MODE_PRIVATE
        )

        if (!prefs.getBoolean(PREF_FULL_SCREEN_SETTINGS_OPENED, false)) {
            prefs.edit()
                .putBoolean(PREF_FULL_SCREEN_SETTINGS_OPENED, true)
                .apply()

            try {
                startActivity(
                    Intent(
                        Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT
                    ).setData(Uri.parse("package:$packageName"))
                )
            } catch (error: Exception) {
                result.error(
                    "FULL_SCREEN_SETTINGS_FAILED",
                    error.message,
                    null
                )
                return
            }
        }

        result.success(manager.canUseFullScreenIntent())
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

        if (requestCode == STARTUP_PERMISSION_REQUEST_CODE) {
            getSharedPreferences(
                STARTUP_PERMISSION_PREFS,
                Context.MODE_PRIVATE
            ).edit()
                .putBoolean(PREF_STARTUP_PERMISSIONS_REQUESTED, true)
                .apply()

            val permissionResults = permissions.mapIndexed { index, permission ->
                permission to (
                    grantResults.getOrNull(index) ==
                        PackageManager.PERMISSION_GRANTED
                )
            }.toMap()

            pendingStartupPermissionResult?.success(permissionResults)
            pendingStartupPermissionResult = null
            return
        }

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
        val groupRoom = intent?.getStringExtra("stellar.group.roomId")
        val groupAction = intent?.getStringExtra("stellar.group.action")
        if (groupRoom != null || groupAction != null) {
            if (groupRoom != null && Regex("[0-9a-f]{32}").matches(groupRoom) &&
                (groupAction == "join" || groupAction == "decline") &&
                intent?.dataString == "stellar-group-action://invitation/$groupRoom/$groupAction" &&
                ecc.stellar.app.calls.StellarGroupCallManager.consumeActionToken(
                    groupRoom, intent?.getStringExtra("stellar.group.token"))) {
                if (pendingGroupActions.size < 4) {
                    pendingGroupActions.putIfAbsent(groupRoom, mapOf(
                        "roomId" to groupRoom, "action" to groupAction
                    ))
                    groupChannel?.invokeMethod("groupActionsAvailable", null)
                }
            }
            intent?.removeExtra("stellar.group.roomId")
            intent?.removeExtra("stellar.group.action")
            intent?.removeExtra("stellar.group.token")
            return
        }
        if (intent?.action == OPEN_WANTED_SECURITY_ACTION) {
            val challengeId = intent.getStringExtra(
                WantedModeForegroundService.EXTRA_CHALLENGE_ID
            )
            getSharedPreferences(
                WANTED_NAV_PREFS,
                Context.MODE_PRIVATE
            ).edit()
                .putBoolean(PREF_PENDING_SECURITY_NAVIGATION, true)
                .putString(PREF_PENDING_SECURITY_CHALLENGE_ID, challengeId)
                .commit()

            if (::wantedModeNavigationChannel.isInitialized) {
                wantedModeNavigationChannel.invokeMethod("openSecurity", null)
            }
            return
        }

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
