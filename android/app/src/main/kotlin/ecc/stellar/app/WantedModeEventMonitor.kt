package ecc.stellar.app

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.Manifest
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.hardware.usb.UsbManager
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Build
import android.os.SystemClock
import org.json.JSONArray
import org.json.JSONObject

/**
 * Explicitly controlled, app-local event audit.
 *
 * Events are logged only while monitoring is enabled.
 * No event causes a wipe, lock, or other destructive operation.
 * Device addresses, names, and network identifiers are not stored.
 */
class WantedModeEventMonitor(context: Context) {

    companion object {
        @Volatile
        private var sharedInstance: WantedModeEventMonitor? = null

        fun getInstance(context: Context): WantedModeEventMonitor {
            return sharedInstance ?: synchronized(this) {
                sharedInstance ?: WantedModeEventMonitor(
                    context.applicationContext
                ).also { sharedInstance = it }
            }
        }

        private const val PREFS = "wanted_mode_event_audit"
        private const val KEY_ENABLED = "monitor_enabled"
        private const val KEY_EVENTS = "events"
        private const val KEY_LAST_ERROR = "last_monitor_error"
        private const val MAX_EVENTS = 100
        private const val DEDUPE_WINDOW_MS = 3000L
    }

    private val appContext = context.applicationContext

    private val prefs = appContext.getSharedPreferences(
        PREFS,
        Context.MODE_PRIVATE
    )

    // Each accepted hardware/network event receives its own durable challenge.
    private val challengeStore = WantedModeChallengeStore(appContext)

    private val connectivityManager =
        appContext.getSystemService(Context.CONNECTIVITY_SERVICE)
            as ConnectivityManager

    private val wifiNetworkRequest = NetworkRequest.Builder()
        .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
        .build()

    private val knownWifiNetworks = mutableSetOf<Network>()
    private val knownUsbHostDevices = mutableSetOf<String>()
    private val lastEventElapsedByType = mutableMapOf<String, Long>()
    private val usbManager = appContext.getSystemService(Context.USB_SERVICE)
        as UsbManager

    @Volatile
    private var listenersRegistered = false

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            when (intent?.action) {
                Intent.ACTION_POWER_CONNECTED ->
                    record("power", "connected")

                UsbManager.ACTION_USB_DEVICE_DETACHED ->
                    record("usb", "disconnected")

                BluetoothAdapter.ACTION_STATE_CHANGED ->
                    record("bluetooth", "changed")

                BluetoothDevice.ACTION_ACL_CONNECTED ->
                    record("bluetooth", "connected")

                BluetoothDevice.ACTION_ACL_DISCONNECTED ->
                    record("bluetooth", "disconnected")
            }
        }
    }

    private val networkCallback =
        object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                synchronized(this@WantedModeEventMonitor) {
                    val wasDisconnected = knownWifiNetworks.isEmpty()
                    if (knownWifiNetworks.add(network) && wasDisconnected) {
                        record("network", "connected")
                    }
                }
            }

            override fun onLost(network: Network) {
                synchronized(this@WantedModeEventMonitor) {
                    if (knownWifiNetworks.remove(network) &&
                        knownWifiNetworks.isEmpty()
                    ) {
                        record("network", "disconnected")
                    }
                }
            }
        }

    @Synchronized
    fun start(): Boolean {
        if (challengeStore.isCorrupted()) {
            saveError("challenge_store_corrupted")
            stop()
            return false
        }

        if (!prefs.edit().putBoolean(KEY_ENABLED, true).commit()) {
            saveError("monitor_preference_write_failed")
            return false
        }

        val started = registerListeners()
        if (started) prefs.edit().remove(KEY_LAST_ERROR).apply()
        return started
    }

    @Synchronized
    fun stop(): Boolean {
        val stopped = unregisterListeners()
        val saved = prefs.edit()
            .putBoolean(KEY_ENABLED, false)
            .commit()

        return stopped && saved
    }

    /**
     * Releases runtime listeners without changing the saved preference.
     * Used when Android destroys the foreground service.
     */
    @Synchronized
    fun releaseListeners(): Boolean {
        return unregisterListeners()
    }

    fun isEnabled(): Boolean =
        prefs.getBoolean(KEY_ENABLED, false)

    private fun saveError(code: String) {
        prefs.edit().putString(KEY_LAST_ERROR, code).commit()
    }

    fun reportRecoveryError(code: String) = saveError(code)

    @Synchronized
    fun getMonitoringHealth(): Map<String, Any> {
        val desired = WantedModeWipeState.isEnabled(appContext)
        val bluetoothGranted = Build.VERSION.SDK_INT < Build.VERSION_CODES.S ||
            appContext.checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) ==
                PackageManager.PERMISSION_GRANTED
        val usbHostSupported = appContext.packageManager.hasSystemFeature(
            PackageManager.FEATURE_USB_HOST
        )
        val error = prefs.getString(KEY_LAST_ERROR, null)
        val status = when {
            !desired -> "STOPPED"
            error != null -> "ERROR"
            !listenersRegistered -> "RECOVERING"
            !bluetoothGranted || !usbHostSupported -> "DEGRADED"
            else -> "ACTIVE"
        }
        return mapOf(
            "status" to status,
            "desired" to desired,
            "listenersRegistered" to listenersRegistered,
            "power" to listenersRegistered,
            "bluetooth" to (listenersRegistered && bluetoothGranted),
            "wifi" to listenersRegistered,
            "usbHost" to (listenersRegistered && usbHostSupported),
            "usbScope" to "HOST_ONLY",
            "error" to (error ?: "")
        )
    }

    // USB_DEVICE_ATTACHED is an Activity intent for host mode and cannot be
    // relied on as a dynamic broadcast. Compare the public host-device list
    // without persisting device names or hardware identifiers.
    @Synchronized
    fun scanUsbHostDevices() {
        if (!listenersRegistered || !isEnabled()) return
        try {
            val current = usbManager.deviceList.keys.toSet()
            if (current.any { it !in knownUsbHostDevices }) {
                record("usb", "connected")
            }
            if (knownUsbHostDevices.any { it !in current }) {
                record("usb", "disconnected")
            }
            knownUsbHostDevices.clear()
            knownUsbHostDevices.addAll(current)
        } catch (_: Exception) {
            saveError("usb_host_scan_failed")
        }
    }

    @Synchronized
    private fun registerListeners(): Boolean {
        if (listenersRegistered) return true
        if (!isEnabled()) return false

        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_POWER_CONNECTED)
            addAction(UsbManager.ACTION_USB_DEVICE_DETACHED)
            addAction(BluetoothAdapter.ACTION_STATE_CHANGED)
            addAction(BluetoothDevice.ACTION_ACL_CONNECTED)
            addAction(BluetoothDevice.ACTION_ACL_DISCONNECTED)
        }

        try {
            if (Build.VERSION.SDK_INT >= 33) {
                appContext.registerReceiver(
                    receiver,
                    filter,
                    Context.RECEIVER_EXPORTED
                )
            } else {
                @Suppress("DEPRECATION")
                appContext.registerReceiver(receiver, filter)
            }
        } catch (_: Exception) {
            prefs.edit().putBoolean(KEY_ENABLED, false).apply()
            saveError("broadcast_registration_failed")
            return false
        }

        try {
            // Seed the current Wi-Fi state before registering. Android may
            // immediately report existing Wi-Fi networks to the callback;
            // those initial reports must not create false challenges.
            knownWifiNetworks.clear()
            knownWifiNetworks.addAll(
                connectivityManager.allNetworks.filter { network ->
                    connectivityManager.getNetworkCapabilities(network)
                        ?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true
                }
            )

            connectivityManager.registerNetworkCallback(
                wifiNetworkRequest,
                networkCallback
            )
        } catch (_: Exception) {
            knownWifiNetworks.clear()
            try {
                appContext.unregisterReceiver(receiver)
            } catch (_: Exception) {
                // Receiver may already have been unregistered.
            }
            prefs.edit().putBoolean(KEY_ENABLED, false).apply()
            saveError("wifi_registration_failed")
            return false
        }

        try {
            knownUsbHostDevices.clear()
            knownUsbHostDevices.addAll(usbManager.deviceList.keys)
        } catch (_: Exception) {
            // Host USB may be unavailable. Do not fabricate an attached event.
            knownUsbHostDevices.clear()
        }
        lastEventElapsedByType.clear()
        listenersRegistered = true
        return true
    }

    @Synchronized
    private fun unregisterListeners(): Boolean {
        if (!listenersRegistered) return true

        var success = true

        try {
            appContext.unregisterReceiver(receiver)
        } catch (_: Exception) {
            success = false
        }

        try {
            connectivityManager.unregisterNetworkCallback(networkCallback)
        } catch (_: Exception) {
            success = false
        }

        knownWifiNetworks.clear()
        knownUsbHostDevices.clear()
        lastEventElapsedByType.clear()
        listenersRegistered = false
        return success
    }

    /**
     * Records only allowlisted categories and actions.
     */
    @Synchronized
    fun record(category: String, action: String): Boolean {
        if (!isEnabled()) return false

        if (category !in setOf("usb", "bluetooth", "network", "power")) {
            return false
        }

        if (action !in setOf(
                "connected",
                "disconnected",
                "changed",
                "unknown"
            )
        ) {
            return false
        }

        val now = System.currentTimeMillis()
        val elapsed = SystemClock.elapsedRealtime()
        val dedupeKey = "$category:$action"
        val lastElapsed = lastEventElapsedByType[dedupeKey]
        if (lastElapsed != null && elapsed >= lastElapsed &&
            elapsed - lastElapsed < DEDUPE_WINDOW_MS
        ) return false
        val events = readEvents()

        val challengeCategory = when (category) {
            "usb" -> "USB"
            "bluetooth" -> "BLUETOOTH"
            "network" -> "NETWORK"
            "power" -> "POWER"
            else -> null
        }

        if (challengeCategory != null && action != "unknown") {
            val challenge = challengeStore.create(
                challengeCategory,
                action
            )

            if (challenge == null) {
                // Fail closed: never keep monitoring without a saved challenge.
                saveError("challenge_save_failed")
                stop()
                return false
            }
        }

        events.put(
            JSONObject()
                .put("category", category)
                .put("action", action)
                .put("time", now)
        )

        while (events.length() > MAX_EVENTS) {
            events.remove(0)
        }

        val saved = prefs.edit()
            .putString(KEY_EVENTS, events.toString())
            .commit()
        if (saved) lastEventElapsedByType[dedupeKey] = elapsed
        else saveError("event_audit_write_failed")
        return saved
    }

    @Synchronized
    fun readAudit(): List<Map<String, Any>> {
        val events = readEvents()
        val result = mutableListOf<Map<String, Any>>()

        for (index in 0 until events.length()) {
            val item = events.optJSONObject(index) ?: continue
            result.add(
                mapOf(
                    "category" to item.optString("category"),
                    "action" to item.optString("action"),
                    "time" to item.optLong("time")
                )
            )
        }

        return result
    }

    private fun readEvents(): JSONArray {
        val raw = prefs.getString(KEY_EVENTS, null)
            ?: return JSONArray()

        return try {
            JSONArray(raw)
        } catch (_: Exception) {
            JSONArray()
        }
    }
}
