package ecc.stellar.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class WantedModeBatteryGuardPolicyTest {

    @Test
    fun triggersOnlyBelowTwentyPercent() {
        val at21 = WantedModeBatteryGuardPolicy.evaluate(true, 21)
        val at20 = WantedModeBatteryGuardPolicy.evaluate(at21.armed, 20)
        val at19 = WantedModeBatteryGuardPolicy.evaluate(at20.armed, 19)

        assertFalse(at21.triggerChallenge)
        assertFalse(at20.triggerChallenge)
        assertTrue(at19.triggerChallenge)
        assertFalse(at19.armed)
    }

    @Test
    fun doesNotRepeatWhileBatteryStaysLow() {
        val first = WantedModeBatteryGuardPolicy.evaluate(true, 19)
        for (percent in listOf(19, 18, 14, 20, 24, 19)) {
            val repeated = WantedModeBatteryGuardPolicy.evaluate(first.armed, percent)
            assertFalse(repeated.triggerChallenge)
            assertFalse(repeated.armed)
        }
    }

    @Test
    fun rearmsAtTwentyFiveForNextDischargeCycle() {
        val triggered = WantedModeBatteryGuardPolicy.evaluate(true, 19)
        val at24 = WantedModeBatteryGuardPolicy.evaluate(triggered.armed, 24)
        val at25 = WantedModeBatteryGuardPolicy.evaluate(at24.armed, 25)
        val nextLow = WantedModeBatteryGuardPolicy.evaluate(at25.armed, 19)

        assertFalse(at24.armed)
        assertTrue(at25.armed)
        assertFalse(at25.triggerChallenge)
        assertTrue(nextLow.triggerChallenge)
    }

    @Test
    fun invalidOrUnavailableReadingsCannotTriggerWipeChallenge() {
        for (percent in listOf(-1, 101, Int.MIN_VALUE, Int.MAX_VALUE)) {
            val result = WantedModeBatteryGuardPolicy.evaluate(true, percent)
            assertFalse(result.triggerChallenge)
            assertTrue(result.armed)
        }
        assertEquals(20, WantedModeBatteryGuardPolicy.TRIGGER_BELOW_PERCENT)
        assertEquals(25, WantedModeBatteryGuardPolicy.REARM_AT_PERCENT)
    }
}
