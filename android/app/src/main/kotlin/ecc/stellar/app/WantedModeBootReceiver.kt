package ecc.stellar.app

import android.Manifest
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build

/** Recovers only monitoring explicitly enabled before device reboot/update. */
class WantedModeBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED &&
            intent.action != Intent.ACTION_MY_PACKAGE_REPLACED
        ) return

        if (!WantedModeWipeState.isEnabled(context) ||
            WantedModeWipeState.hasPending(context)
        ) return

        val monitor = WantedModeEventMonitor.getInstance(context)
        if (intent.action == Intent.ACTION_BOOT_COMPLETED &&
            !WantedModeChallengeStore(context).markPendingRecoveredFromBoot()
        ) {
            monitor.reportRecoveryError("reboot_challenge_recovery_failed")
            return
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
            context.checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) !=
                PackageManager.PERMISSION_GRANTED
        ) {
            monitor.reportRecoveryError("bluetooth_permission_missing_after_boot")
            return
        }

        try {
            val service = Intent(context, WantedModeForegroundService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(service)
            } else {
                context.startService(service)
            }
        } catch (_: Exception) {
            // Android may disallow this background start. Keep the preference,
            // report degraded recovery, and retry on the next app launch.
            monitor.reportRecoveryError("background_service_restart_restricted")
        }
    }
}
