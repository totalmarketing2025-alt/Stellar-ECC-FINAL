package ecc.stellar.app

import android.content.Context
import android.os.SystemClock
import android.provider.Settings
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

/**
 * Durable, non-destructive storage for independent Wanted Mode challenges.
 *
 * This class never locks the app or wipes data.
 * Expired challenges remain stored until explicitly acknowledged.
 */
class WantedModeChallengeStore(context: Context) {

    data class Challenge(
        val id: String,
        val category: String,
        val action: String,
        val createdAtMillis: Long,
        val deadlineMillis: Long,
        val expired: Boolean,
        val createdAtElapsedMillis: Long = -1L,
        val bootCount: Int = -1,
        val recoveredFromReboot: Boolean = false
    )

    companion object {
        private const val PREFS = "wanted_mode_challenges_v1"
        private const val KEY_CHALLENGES = "challenges"
        private const val KEY_CORRUPTED = "challenges_corrupted"
        private const val TIMEOUT_MILLIS = 10_000L
        private const val MAX_CHALLENGES = 50

        private val ALLOWED_CATEGORIES =
            setOf("USB", "BLUETOOTH", "NETWORK", "POWER", "BATTERY")

        private val ALLOWED_ACTIONS =
            setOf("connected", "disconnected", "changed", "low")

        private fun allowedType(category: String, action: String): Boolean =
            category in ALLOWED_CATEGORIES && action in ALLOWED_ACTIONS &&
                ((category == "BATTERY") == (action == "low"))
    }

    private val prefs =
        context.applicationContext.getSharedPreferences(
            PREFS,
            Context.MODE_PRIVATE
        )

    private val appContext = context.applicationContext

    private fun bootCount(): Int = try {
        Settings.Global.getInt(
            appContext.contentResolver,
            Settings.Global.BOOT_COUNT,
            -1
        )
    } catch (_: Exception) {
        -1
    }

    // The wall clock is retained for audit/display and legacy records only.
    // Android's elapsed clock cannot be moved by automatic time sync.
    private fun isRecoveredAcrossBoot(challenge: Challenge): Boolean {
        val currentBoot = bootCount()
        return challenge.recoveredFromReboot ||
            (challenge.bootCount >= 0 && currentBoot >= 0 &&
                challenge.bootCount != currentBoot) ||
            (challenge.createdAtElapsedMillis >= 0 &&
                SystemClock.elapsedRealtime() < challenge.createdAtElapsedMillis)
    }

    private fun deadlinePassed(challenge: Challenge): Boolean {
        if (isRecoveredAcrossBoot(challenge)) return true
        if (challenge.createdAtElapsedMillis >= 0) {
            return SystemClock.elapsedRealtime() -
                challenge.createdAtElapsedMillis >= TIMEOUT_MILLIS
        }
        return System.currentTimeMillis() >= challenge.deadlineMillis
    }

    fun remainingMillis(challenge: Challenge): Long {
        if (deadlinePassed(challenge)) return 0L
        if (challenge.createdAtElapsedMillis >= 0) {
            return (TIMEOUT_MILLIS -
                (SystemClock.elapsedRealtime() - challenge.createdAtElapsedMillis))
                .coerceAtLeast(0L)
        }
        return (challenge.deadlineMillis - System.currentTimeMillis())
            .coerceAtLeast(0L)
    }

    /** A reboot cancels the timing authority of every pre-boot challenge.
     * Keep the audit history, but never turn an old deadline into a new wipe.
     */
    @Synchronized
    fun markPendingRecoveredFromBoot(): Boolean {
        if (isCorrupted()) return false
        val current = readAll()
        if (isCorrupted()) return false
        return writeAll(current.map { challenge ->
            if (challenge.expired) challenge else challenge.copy(
                expired = true,
                recoveredFromReboot = true
            )
        })
    }

    @Volatile
    private var corruptionDetectedInProcess = false

    @Synchronized
    fun isCorrupted(): Boolean {
        return corruptionDetectedInProcess ||
            prefs.getBoolean(KEY_CORRUPTED, false)
    }

    @Synchronized
    private fun markCorrupted() {
        corruptionDetectedInProcess = true
        prefs.edit()
            .putBoolean(KEY_CORRUPTED, true)
            .commit()
    }

    @Synchronized
    fun create(
        category: String,
        action: String
    ): Challenge? {
        if (!allowedType(category, action)) return null
        if (isCorrupted()) return null

        val now = System.currentTimeMillis()
        val challenge = Challenge(
            id = UUID.randomUUID().toString(),
            category = category,
            action = action,
            createdAtMillis = now,
            deadlineMillis = now + TIMEOUT_MILLIS,
            expired = false,
            createdAtElapsedMillis = SystemClock.elapsedRealtime(),
            bootCount = bootCount()
        )

        val current = readAll().toMutableList()
        if (isCorrupted()) return null

        // Keep unresolved challenges. Never silently discard a pending
        // or expired challenge to make room for a new one.
        if (current.size >= MAX_CHALLENGES) return null

        current.add(challenge)

        return if (writeAll(current)) challenge else null
    }

    @Synchronized
    fun getPending(): List<Challenge> {
        if (isCorrupted()) return emptyList()
        val all = readAll()
        if (isCorrupted()) return emptyList()

        return all
            .filter { !it.expired && !deadlinePassed(it) }
            .sortedBy { it.createdAtMillis }
    }

    @Synchronized
    fun getExpired(): List<Challenge> {
        if (isCorrupted()) return emptyList()

        val all = readAll()
        if (isCorrupted()) return emptyList()
        val updated = all.map {
            if (!it.expired && deadlinePassed(it)) {
                it.copy(
                    expired = true,
                    recoveredFromReboot = isRecoveredAcrossBoot(it)
                )
            } else {
                it
            }
        }

        if (updated != all && !writeAll(updated)) {
            return emptyList()
        }

        return updated
            .filter { it.expired }
            .sortedBy { it.deadlineMillis }
    }

    @Synchronized
    fun resolve(id: String): Boolean {
        if (id.isBlank() || isCorrupted()) return false

        val current = readAll()
        if (isCorrupted()) return false
        val challenge = current.firstOrNull { it.id == id }
            ?: return false

        // A challenge cannot be resolved after its deadline.
        if (challenge.expired || deadlinePassed(challenge)) {
            return false
        }

        return writeAll(current.filterNot { it.id == id })
    }

    @Synchronized
    fun acknowledgeExpired(id: String): Boolean {
        if (id.isBlank() || isCorrupted()) return false

        val current = readAll()
        if (isCorrupted()) return false
        val challenge = current.firstOrNull { it.id == id }
            ?: return false

        if (!challenge.expired && !deadlinePassed(challenge)) {
            return false
        }

        return writeAll(current.filterNot { it.id == id })
    }

    @Synchronized
    fun readAll(): List<Challenge> {
        if (isCorrupted()) return emptyList()

        val raw = prefs.getString(KEY_CHALLENGES, null)
            ?: return emptyList()

        return try {
            val array = JSONArray(raw)
            val result = mutableListOf<Challenge>()

            for (i in 0 until array.length()) {
                val item = array.optJSONObject(i)
                if (item == null) {
                    markCorrupted()
                    return emptyList()
                }

                val id = item.optString("id")
                val category = item.optString("category")
                val action = item.optString("action")
                val created = item.optLong("createdAtMillis", -1L)
                val deadline = item.optLong("deadlineMillis", -1L)

                if (id.isBlank() ||
                    !allowedType(category, action) ||
                    created <= 0L ||
                    deadline <= created ||
                    !item.has("expired")
                ) {
                    markCorrupted()
                    return emptyList()
                }

                result.add(
                    Challenge(
                        id = id,
                        category = category,
                        action = action,
                        createdAtMillis = created,
                        deadlineMillis = deadline,
                        expired = item.optBoolean("expired", false),
                        createdAtElapsedMillis =
                            item.optLong("createdAtElapsedMillis", -1L),
                        bootCount = item.optInt("bootCount", -1),
                        recoveredFromReboot =
                            item.optBoolean("recoveredFromReboot", false)
                    )
                )
            }

            result
        } catch (_: Exception) {
            markCorrupted()
            emptyList()
        }
    }

    private fun writeAll(challenges: List<Challenge>): Boolean {
        if (isCorrupted()) return false

        val array = JSONArray()

        challenges.forEach { challenge ->
            array.put(
                JSONObject().apply {
                    put("id", challenge.id)
                    put("category", challenge.category)
                    put("action", challenge.action)
                    put("createdAtMillis", challenge.createdAtMillis)
                    put("deadlineMillis", challenge.deadlineMillis)
                    put("expired", challenge.expired)
                    put("createdAtElapsedMillis", challenge.createdAtElapsedMillis)
                    put("bootCount", challenge.bootCount)
                    put("recoveredFromReboot", challenge.recoveredFromReboot)
                }
            )
        }

        return prefs.edit()
            .putString(KEY_CHALLENGES, array.toString())
            .commit()
    }
}
