package ecc.stellar.app

/**
 * Strictly validates the metadata used to wake the native incoming-call path.
 * This is not call authentication: the actual offer is authenticated in Flutter.
 */
internal data class StellarCallWake(
    val callId: String,
    val remote: String,
    val kind: String,
    val chatId: String?
) {
    companion object {
        fun parse(data: Map<String, String>): StellarCallWake? {
            if (data["type"] != "call") return null
            val callId = data["callId"]?.trim().orEmpty()
            val remote = (data["from"]?.takeIf { it.isNotBlank() }
                ?: data["remoteNickname"]).orEmpty().trim()
            val kind = data["kind"]?.lowercase()?.trim() ?: "voice"
            if (callId.isEmpty() || callId.length > 128 ||
                remote.isEmpty() || remote.length > 128 ||
                kind !in setOf("voice", "video")) return null
            if (callId.any { Character.isISOControl(it) } ||
                remote.any { Character.isISOControl(it) }) return null
            return StellarCallWake(callId, remote, kind,
                data["chatId"]?.takeIf { it.isNotBlank() && it.length <= 128 })
        }
    }
}
