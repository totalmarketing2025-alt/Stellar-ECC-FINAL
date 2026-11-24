package ecc.stellar.app

/**
 * Untrusted wake metadata only. A signed relay invitation and current
 * membership must be verified in Flutter before joining or opening media.
 */
internal data class StellarGroupCallWake(
    val roomId: String,
    val sentAt: Long
) {
    companion object {
        private val roomPattern = Regex("[0-9a-f]{32}")
        private const val MAX_AGE_MS = 45_000L
        private const val MAX_FUTURE_MS = 5_000L

        fun parse(
            data: Map<String, String>,
            now: Long = System.currentTimeMillis()
        ): StellarGroupCallWake? {
            if (data["type"] != "group-call") return null
            val room = data["roomId"] ?: return null
            if (!roomPattern.matches(room)) return null
            val sentAt = data["sentAt"]?.toLongOrNull() ?: return null
            if (sentAt <= 0 || sentAt < now - MAX_AGE_MS ||
                sentAt > now + MAX_FUTURE_MS) return null
            return StellarGroupCallWake(room, sentAt)
        }
    }
}
