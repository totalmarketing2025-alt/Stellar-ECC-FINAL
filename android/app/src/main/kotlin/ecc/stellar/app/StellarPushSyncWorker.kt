package ecc.stellar.app

import android.content.Context
import android.util.Log
import androidx.work.CoroutineWorker
import androidx.work.WorkerParameters

class StellarPushSyncWorker(
    appContext: Context,
    workerParams: WorkerParameters
) : CoroutineWorker(appContext, workerParams) {

    override suspend fun doWork(): Result {
        Log.d(
            "StellarFCM",
            "FIX1 Worker started"
        )

        return try {
            val success =
                StellarPushBackgroundRunner.run(applicationContext)

            if (success) {
                Log.d(
                    "StellarFCM",
                    "FIX1 Worker completed"
                )

                Result.success()
            } else {
                Log.w(
                    "StellarFCM",
                    "FIX1 Worker sync incomplete; retrying"
                )

                Result.retry()
            }
        } catch (error: Throwable) {
            Log.e(
                "StellarFCM",
                "FIX1 Worker failed",
                error
            )

            Result.retry()
        }
    }
}
