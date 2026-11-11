package ecc.stellar.app

import org.junit.Assert.*
import org.junit.Test

class StellarCallWakeTest {
    @Test fun acceptsVoiceAndVideo() {
        val voice = StellarCallWake.parse(mapOf(
            "type" to "call", "callId" to "abc", "from" to "alice"))
        assertEquals("voice", voice?.kind)
        assertEquals("alice", voice?.remote)
        val video = StellarCallWake.parse(mapOf(
            "type" to "call", "callId" to "xyz",
            "remoteNickname" to "bob", "kind" to "VIDEO"))
        assertEquals("video", video?.kind)
    }

    @Test fun rejectsNonCallAndMissingIdentity() {
        assertNull(StellarCallWake.parse(mapOf("type" to "message",
            "callId" to "abc", "from" to "alice")))
        assertNull(StellarCallWake.parse(mapOf("type" to "call", "from" to "alice")))
        assertNull(StellarCallWake.parse(mapOf("type" to "call", "callId" to "abc")))
    }

    @Test fun rejectsInvalidKindAndControlCharacters() {
        assertNull(StellarCallWake.parse(mapOf("type" to "call",
            "callId" to "abc", "from" to "alice", "kind" to "unknown")))
        assertNull(StellarCallWake.parse(mapOf("type" to "call",
            "callId" to "a\n", "from" to "alice")))
    }

    @Test fun rejectsOversizedMetadata() {
        assertNull(StellarCallWake.parse(mapOf("type" to "call",
            "callId" to "a".repeat(129), "from" to "alice")))
        assertNull(StellarCallWake.parse(mapOf("type" to "call",
            "callId" to "abc", "from" to "b".repeat(129))))
    }
}
