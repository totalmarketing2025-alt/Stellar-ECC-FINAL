package ecc.stellar.app

import android.content.Context

object WantedModeWipeState {
    private const val PREFS = "stellar_wanted_mode_wipe"
    private const val KEY_ENABLED = "wipe_enabled"
    private const val KEY_PENDING = "pending_local_wipe"

    fun isEnabled(context: Context): Boolean {
        return context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getBoolean(KEY_ENABLED, false)
    }

    fun setEnabled(context: Context, enabled: Boolean): Boolean {
        return context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .putBoolean(KEY_ENABLED, enabled)
            .commit()
    }

    fun hasPending(context: Context): Boolean {
        return context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getBoolean(KEY_PENDING, false)
    }

    fun request(context: Context): Boolean {
        return context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .putBoolean(KEY_PENDING, true)
            .commit()
    }

    fun complete(context: Context): Boolean {
        fun clearPreferences(name: String): Boolean {
            return context.getSharedPreferences(name, Context.MODE_PRIVATE)
                .edit()
                .clear()
                .commit()
        }

        // Чистиме само локални Wanted Mode и call-state податоци.
        if (!clearPreferences("wanted_mode_challenges_v1")) return false
        if (!clearPreferences("wanted_mode_event_audit")) return false
        if (!clearPreferences("stellar_call_state")) return false

        // Pending marker се отстранува последен.
        val wipePrefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val cleared = wipePrefs.edit().clear().commit()

        if (!cleared) {
            // Повторно го поставуваме marker-от ако последниот commit не успее.
            wipePrefs.edit().putBoolean(KEY_PENDING, true).commit()
            return false
        }

        return true
    }
}
