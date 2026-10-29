package ecc.stellar.app

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbManager
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.Build
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
        private const val PREFS = "wanted_mode_event_audit"
        private const val KEY_ENABLED = "monitor_enabled"
        private const val KEY_EVENTS = "events"
        private const val MAX_EVENTS = 100
        private const val DEDUPE_WINDOW_MS = 3000L
    }

    private val appContext = context.applicationContext

    private val prefs = appContext.getSharedPreferences(
        PREFS,
        Context.MODE_PRIVATE
    )

    private val connectivityManager =
        appContext.getSystemService(Context.CONNECTIVITY_SERVICE)
            as ConnectivityManager

    @Volatile
    private var listenersRegistered = false

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            when (intent?.action) {
                UsbManager.ACTION_USB_DEVICE_ATTACHED ->
                    record("usb", "connected")

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
                record("network", "connected")
            }

            override fun onLost(network: Network) {
                record("network", "disconnected")
            }

            override fun onCapabilitiesChanged(
                network: Network,
                capabilities: NetworkCapabilities
            ) {
                record("network", "changed")
            }
        }

    init {
        // Restore monitoring after activity/process recreation if it was enabled.
        if (isEnabled()) {
            registerListeners()
        }
    }

    @Synchronized
    fun start(): Boolean {
        if (!prefs.edit().putBoolean(KEY_ENABLED, true).commit()) {
            return false
        }

        return registerListeners()
    }

    @Synchronized
    fun stop(): Boolean {
        val stopped = unregisterListeners()
        val saved = prefs.edit()
            .putBoolean(KEY_ENABLED, false)
            .commit()

        return stopped && saved
    }

    fun isEnabled(): Boolean =
        prefs.getBoolean(KEY_ENABLED, false)

    @Synchronized
    private fun registerListeners(): Boolean {
        if (listenersRegistered) return true
        if (!isEnabled()) return false

        val filter = IntentFilter().apply {
            addAction(UsbManager.ACTION_USB_DEVICE_ATTACHED)
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
            return false
        }

        try {
            connectivityManager.registerDefaultNetworkCallback(
                networkCallback
            )
        } catch (_: Exception) {
            try {
                appContext.unregisterReceiver(receiver)
            } catch (_: Exception) {
                // Receiver may already have been unregistered.
            }
            prefs.edit().putBoolean(KEY_ENABLED, false).apply()
            return false
        }

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

        listenersRegistered = false
        return success
    }

    /**
     * Records only allowlisted categories and actions.
     */
    @Synchronized
    fun record(category: String, action: String): Boolean {
        if (!isEnabled()) return false

        if (category !in setOf("usb", "bluetooth", "network")) {
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
        val events = readEvents()

        if (events.length() > 0) {
            val last = events.optJSONObject(events.length() - 1)
            if (last != null &&
                last.optString("category") == category &&
                last.optString("action") == action &&
                now - last.optLong("time") < DEDUPE_WINDOW_MS
            ) {
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

        return prefs.edit()
            .putString(KEY_EVENTS, events.toString())
            .commit()
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
