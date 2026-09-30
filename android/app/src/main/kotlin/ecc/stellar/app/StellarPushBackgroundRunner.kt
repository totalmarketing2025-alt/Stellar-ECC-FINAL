package ecc.stellar.app

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.embedding.engine.loader.FlutterLoader
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

object StellarPushBackgroundRunner {

    private const val CHANNEL = "ecc.stellar.app/push_background"
    private const val TIMEOUT_SECONDS = 15L

    private val engineLock = Any()

    fun run(context: Context): Boolean {
        val latch = CountDownLatch(1)
        val completed = AtomicBoolean(false)
        val success = AtomicBoolean(false)
        val engineRef = arrayOfNulls<FlutterEngine>(1)

        Handler(Looper.getMainLooper()).post {
            if (completed.get()) {
                return@post
            }

            synchronized(engineLock) {
                if (completed.get()) {
                    return@synchronized
                }

                try {
                    val loader = FlutterLoader()

                    loader.startInitialization(context)
                    loader.ensureInitializationComplete(context, null)

                    val engine = FlutterEngine(context)
                    engineRef[0] = engine

                    val channel = MethodChannel(
                        engine.dartExecutor.binaryMessenger,
                        CHANNEL
                    )

                    channel.setMethodCallHandler { call, result ->
                        if (call.method == "backgroundComplete") {
                            val backgroundSuccess =
                                call.arguments as? Boolean ?: true

                            if (completed.compareAndSet(false, true)) {
                                success.set(backgroundSuccess)
                                result.success(backgroundSuccess)
                                latch.countDown()

                                try {
                                    engine.destroy()
                                } catch (error: Throwable) {
                                    Log.e(
                                        "StellarFCM",
                                        "Background engine destroy failed",
                                        error
                                    )
                                } finally {
                                    engineRef[0] = null
                                }
                            }
                        } else {
                            result.notImplemented()
                        }
                    }

                    engine.dartExecutor.executeDartEntrypoint(
                        DartExecutor.DartEntrypoint(
                            loader.findAppBundlePath(),
                            "stellarPushBackgroundMain"
                        )
                    )

                    Log.d(
                        "StellarFCM",
                        "FIX1 headless Flutter engine started"
                    )
                } catch (error: Throwable) {
                    Log.e(
                        "StellarFCM",
                        "FIX1 headless engine failed",
                        error
                    )

                    if (completed.compareAndSet(false, true)) {
                        try {
                            engineRef[0]?.destroy()
                        } catch (_: Throwable) {
                        } finally {
                            engineRef[0] = null
                        }

                        latch.countDown()
                    }
                }
            }
        }

        try {
            val finished = latch.await(
                TIMEOUT_SECONDS,
                TimeUnit.SECONDS
            )

            if (!finished) {
                Log.w(
                    "StellarFCM",
                    "FIX1 background sync timeout"
                )

                if (completed.compareAndSet(false, true)) {
                    Handler(Looper.getMainLooper()).post {
                        try {
                            engineRef[0]?.destroy()
                        } catch (error: Throwable) {
                            Log.e(
                                "StellarFCM",
                                "Background engine timeout destroy failed",
                                error
                            )
                        } finally {
                            engineRef[0] = null
                        }
                    }
                }

                return false
            }

            return success.get()
        } catch (error: InterruptedException) {
            Thread.currentThread().interrupt()

            Log.e(
                "StellarFCM",
                "FIX1 background sync interrupted",
                error
            )

            Handler(Looper.getMainLooper()).post {
                try {
                    engineRef[0]?.destroy()
                } catch (destroyError: Throwable) {
                    Log.e(
                        "StellarFCM",
                        "Background engine interrupt destroy failed",
                        destroyError
                    )
                } finally {
                    engineRef[0] = null
                }
            }

            return false
        }
    }
}
