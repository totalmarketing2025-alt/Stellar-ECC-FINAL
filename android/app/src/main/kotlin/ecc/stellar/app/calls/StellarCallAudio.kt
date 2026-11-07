package ecc.stellar.app.calls

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.media.ToneGenerator
import android.util.Log

object StellarCallAudio {
    private const val TAG = "StellarCallAudio"

    private val incomingPlayers = mutableMapOf<String, MediaPlayer>()
    private val outgoingTones = mutableMapOf<String, ToneGenerator>()

    @Synchronized
    fun startIncomingRingtone(context: Context, callId: String) {
        if (callId.isBlank()) return
        stop(callId)

        val uri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
            ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION)
            ?: return

        val player = MediaPlayer()

        try {
            player.setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build()
            )
            player.isLooping = true
            player.setDataSource(context.applicationContext, uri)
            incomingPlayers[callId] = player

            player.setOnPreparedListener { prepared ->
                synchronized(this) {
                    if (incomingPlayers[callId] === prepared) {
                        runCatching { prepared.start() }
                    } else {
                        runCatching { prepared.release() }
                    }
                }
            }

            player.setOnErrorListener { failed, what, extra ->
                synchronized(this) {
                    if (incomingPlayers[callId] === failed) {
                        incomingPlayers.remove(callId)
                    }
                    runCatching { failed.release() }
                }
                Log.w(TAG, "Incoming ringtone playback failed: $what/$extra")
                true
            }

            player.prepareAsync()
        } catch (error: Exception) {
            incomingPlayers.remove(callId)
            runCatching { player.release() }
            Log.w(TAG, "Could not start incoming ringtone", error)
        }
    }

    @Synchronized
    fun startOutgoingRingback(callId: String) {
        if (callId.isBlank()) return
        stop(callId)

        try {
            val tone = ToneGenerator(AudioManager.STREAM_RING, 80)
            outgoingTones[callId] = tone

            if (!tone.startTone(ToneGenerator.TONE_SUP_RINGTONE, 60_000)) {
                outgoingTones.remove(callId)
                tone.release()
                Log.w(TAG, "Android rejected outgoing ringback tone")
            }
        } catch (error: Exception) {
            outgoingTones.remove(callId)?.let {
                runCatching { it.release() }
            }
            Log.w(TAG, "Could not start outgoing ringback", error)
        }
    }

    @Synchronized
    fun stop(callId: String) {
        if (callId.isBlank()) return

        incomingPlayers.remove(callId)?.let { player ->
            runCatching {
                if (player.isPlaying) player.stop()
            }
            runCatching { player.reset() }
            runCatching { player.release() }
        }

        outgoingTones.remove(callId)?.let { tone ->
            runCatching { tone.stopTone() }
            runCatching { tone.release() }
        }
    }
}
