package ecc.stellar.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class StellarGroupCallWakeTest {
    private val now = 1_700_000_000_000L
    private val roomId = "1234567890abcdef1234567890abcdef"

    @Test
    fun acceptsFreshGroupWakeMetadata() {
        val wake = StellarGroupCallWake.parse(mapOf(
            "type" to "group-call",
            "roomId" to roomId,
            "sentAt" to (now - 10_000L).toString(),
        ), now)

        assertEquals(roomId, wake?.roomId)
        assertEquals(now - 10_000L, wake?.sentAt)
    }

    @Test
    fun rejectsWrongTypeMalformedRoomAndInvalidTimestamp() {
        assertNull(StellarGroupCallWake.parse(mapOf(
            "type" to "call", "roomId" to roomId, "sentAt" to now.toString(),
        ), now))
        assertNull(StellarGroupCallWake.parse(mapOf(
            "type" to "group-call", "roomId" to "short", "sentAt" to now.toString(),
        ), now))
        assertNull(StellarGroupCallWake.parse(mapOf(
            "type" to "group-call", "roomId" to roomId, "sentAt" to "bad",
        ), now))
        assertNull(StellarGroupCallWake.parse(mapOf(
            "type" to "group-call", "roomId" to roomId, "sentAt" to "0",
        ), now))
    }

    @Test
    fun rejectsExpiredAndExcessivelyFutureDatedWake() {
        assertNull(StellarGroupCallWake.parse(mapOf(
            "type" to "group-call",
            "roomId" to roomId,
            "sentAt" to (now - 45_001L).toString(),
        ), now))
        assertNull(StellarGroupCallWake.parse(mapOf(
            "type" to "group-call",
            "roomId" to roomId,
            "sentAt" to (now + 5_001L).toString(),
        ), now))
    }
}
