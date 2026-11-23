package ecc.stellar.app

import android.animation.ValueAnimator
import android.app.NotificationManager
import android.content.Context
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import android.util.Log
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.roundToInt
import kotlin.math.sin

/**
 * Opt-in, time-limited edge light for background message notifications.
 *
 * TYPE_APPLICATION_OVERLAY may be hidden by the keyguard or device vendor.
 * The system notification remains the guaranteed fallback. This does NOT
 * wake the display, launch an Activity, or use call-only full-screen intents.
 */
object StellarEdgeLighting {
    private const val PREFS = "stellar_edge_lighting"
    private const val ENABLED = "background_edge_enabled"
    private const val DURATION_MS = 2200L

    private val handler = Handler(Looper.getMainLooper())
    private var currentManager: WindowManager? = null
    private var currentViews: List<View> = emptyList()
    private var currentAnimator: ValueAnimator? = null

    @Volatile private var appForeground = false

    fun setAppForeground(value: Boolean) {
        appForeground = value
        if (value) handler.post { clearCurrent() }
    }

    fun supported(): Boolean = Build.VERSION.SDK_INT >= 26

    fun permissionGranted(context: Context): Boolean =
        supported() && Settings.canDrawOverlays(context)

    fun enabled(context: Context): Boolean =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getBoolean(ENABLED, false)

    fun setEnabled(context: Context, value: Boolean): Boolean {
        val accepted = value && permissionGranted(context)
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit().putBoolean(ENABLED, accepted).apply()
        if (!accepted) handler.post { clearCurrent() }
        return accepted
    }

    fun state(context: Context): Map<String, Boolean> = mapOf(
        "supported" to supported(),
        "permissionGranted" to permissionGranted(context),
        "enabled" to enabled(context)
    )

    fun showForMessage(context: Context) {
        val app = context.applicationContext
        val notificationManager =
            app.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val powerManager = app.getSystemService(Context.POWER_SERVICE) as PowerManager
        val permittedByDnd =
            notificationManager.currentInterruptionFilter ==
                NotificationManager.INTERRUPTION_FILTER_ALL
        if (!StellarEdgeLightingPolicy.shouldShow(
                enabled = enabled(app),
                permissionGranted = permissionGranted(app),
                appForeground = appForeground,
                screenInteractive = powerManager.isInteractive,
                dndAllowed = permittedByDnd,
                wipePending = WantedModeWipeState.hasPending(app)
            )
        ) return

        handler.post {
            if (!enabled(app) || !permissionGranted(app) || appForeground ||
                WantedModeWipeState.hasPending(app)) return@post
            clearCurrent()
            try {
                val manager =
                    app.getSystemService(Context.WINDOW_SERVICE) as WindowManager
                val left = newEdge(app, left = true)
                val right = newEdge(app, left = false)
                val flags = WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                    WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or
                    WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
                    WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN
                val width = (16 * app.resources.displayMetrics.density).roundToInt()
                fun params(gravity: Int) = WindowManager.LayoutParams(
                    width,
                    WindowManager.LayoutParams.MATCH_PARENT,
                    WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
                    flags,
                    PixelFormat.TRANSLUCENT
                ).apply {
                    this.gravity = gravity or Gravity.TOP
                    // Keep the overlay translucent and noninteractive.
                    alpha = 0.65f
                    title = "Stellar message edge lighting"
                }

                manager.addView(left, params(Gravity.START))
                currentManager = manager
                currentViews = listOf(left)
                manager.addView(right, params(Gravity.END))
                currentViews = listOf(left, right)

                currentAnimator = ValueAnimator.ofFloat(0f, 1f).apply {
                    duration = DURATION_MS
                    addUpdateListener { animation ->
                        val progress = animation.animatedValue as Float
                        // Two pulses with decreasing brightness.
                        val intensity = abs(sin(progress * 2.0 * PI)) *
                            (1.0 - progress)
                        val alpha = (215 * intensity).roundToInt().coerceIn(0, 215)
                        left.background.alpha = alpha
                        right.background.alpha = alpha
                    }
                    addListener(object : android.animation.AnimatorListenerAdapter() {
                        override fun onAnimationEnd(animation: android.animation.Animator) {
                            clearCurrent()
                        }
                    })
                    start()
                }
            } catch (error: Throwable) {
                Log.w("StellarEdge", "Edge overlay unavailable; notification remains", error)
                clearCurrent()
            }
        }
    }

    private fun newEdge(context: Context, left: Boolean): View =
        View(context).apply {
            background = GradientDrawable(
                if (left) GradientDrawable.Orientation.LEFT_RIGHT
                else GradientDrawable.Orientation.RIGHT_LEFT,
                intArrayOf(
                    Color.rgb(139, 92, 246),
                    Color.argb(84, 139, 92, 246),
                    Color.TRANSPARENT
                )
            ).apply { alpha = 0 }
        }

    private fun clearCurrent() {
        currentAnimator?.removeAllListeners()
        currentAnimator?.cancel()
        currentAnimator = null
        val manager = currentManager
        currentViews.forEach { view ->
            try { manager?.removeViewImmediate(view) } catch (_: Throwable) {}
        }
        currentViews = emptyList()
        currentManager = null
    }
}

/** Pure policy to keep background lighting out of sensitive states. */
object StellarEdgeLightingPolicy {
    fun shouldShow(
        enabled: Boolean,
        permissionGranted: Boolean,
        appForeground: Boolean,
        screenInteractive: Boolean,
        dndAllowed: Boolean,
        wipePending: Boolean
    ): Boolean = enabled && permissionGranted && !appForeground &&
        screenInteractive && dndAllowed && !wipePending
}
