package ecc.stellar.app.calls

import android.os.SystemClock

/**
 * Native state for invitations verified by Flutter, never raw FCM metadata.
 * No media or Telecom connection is started by this registry.
 */
internal object StellarGroupCallManager {
    private const val MAX_PENDING = 4
    private const val TTL_MS = 45_000L
    private val roomPattern = Regex("[0-9a-f]{32}")
    private val pending = linkedMapOf<String, Long>()

    @Synchronized
    fun registerVerifiedInvitation(roomId: String): Boolean {
        if (!roomPattern.matches(roomId)) return false
        val now = SystemClock.elapsedRealtime()
        pending.entries.removeAll { it.value <= now }
        if (pending.containsKey(roomId) || pending.size >= MAX_PENDING) return false
        pending[roomId] = now + TTL_MS
        return true
    }

    @Synchronized
    fun isPending(roomId: String): Boolean {
        val expires = pending[roomId] ?: return false
        if (expires <= SystemClock.elapsedRealtime()) {
            pending.remove(roomId)
            return false
        }
        return true
    }

    @Synchronized
    fun consumeInvitation(roomId: String): Boolean {
        val expires = pending.remove(roomId) ?: return false
        return expires > SystemClock.elapsedRealtime()
    }

    @Synchronized
    fun dismiss(roomId: String) {
        pending.remove(roomId)
    }

    @Synchronized
    fun clear() {
        pending.clear()
    }
}
