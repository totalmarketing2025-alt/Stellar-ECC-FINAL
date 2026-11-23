package ecc.stellar.app

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class StellarEdgeLightingPolicyTest {
    private fun allowed(
        enabled: Boolean = true,
        permissionGranted: Boolean = true,
        appForeground: Boolean = false,
        screenInteractive: Boolean = true,
        dndAllowed: Boolean = true,
        wipePending: Boolean = false
    ) = StellarEdgeLightingPolicy.shouldShow(
        enabled = enabled,
        permissionGranted = permissionGranted,
        appForeground = appForeground,
        screenInteractive = screenInteractive,
        dndAllowed = dndAllowed,
        wipePending = wipePending
    )

    @Test
    fun allowsBackgroundMessagePulseOnlyWithExplicitOptIn() {
        assertTrue(allowed())
        assertFalse(allowed(enabled = false))
        assertFalse(allowed(permissionGranted = false))
    }

    @Test
    fun neverOverlaysForegroundOrOffScreen() {
        assertFalse(allowed(appForeground = true))
        assertFalse(allowed(screenInteractive = false))
    }

    @Test
    fun suppressesVisualInterruptionsDuringDndAndPendingWipe() {
        assertFalse(allowed(dndAllowed = false))
        assertFalse(allowed(wipePending = true))
    }
}
