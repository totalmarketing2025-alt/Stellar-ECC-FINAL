package ecc.stellar.app

/** Pure threshold policy. A low-battery challenge is issued once per discharge cycle. */
internal object WantedModeBatteryGuardPolicy {
    const val TRIGGER_BELOW_PERCENT = 20
    const val REARM_AT_PERCENT = 25

    data class Decision(
        val armed: Boolean,
        val triggerChallenge: Boolean
    )

    fun evaluate(armed: Boolean, percent: Int): Decision = when {
        percent !in 0..100 -> Decision(armed, false)
        percent >= REARM_AT_PERCENT -> Decision(true, false)
        percent < TRIGGER_BELOW_PERCENT && armed -> Decision(false, true)
        else -> Decision(armed, false)
    }
}
