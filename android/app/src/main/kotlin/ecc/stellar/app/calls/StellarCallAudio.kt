package ecc.stellar.app.calls

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.media.ToneGenerator
import android.util.Log

object StellarCallAudio {
    private const val TAG = "StellarCallAudio"

    private data class FocusEntry(
        val manager: AudioManager,
        val request: AudioFocusRequest
    )

    private val incomingPlayers = mutableMapOf<String, MediaPlayer>()
    private val outgoingTones = mutableMapOf<String, ToneGenerator>()
    private val audioFocus = mutableMapOf<String, FocusEntry>()

    private fun ringtoneAttributes(): AudioAttributes =
        AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
            .build()

    private fun requestAudioFocus(context: Context, callId: String) {
        try {
            val manager = context.applicationContext
                .getSystemService(Context.AUDIO_SERVICE) as AudioManager

            val request = AudioFocusRequest.Builder(
                AudioManager.AUDIOFOCUS_GAIN_TRANSIENT
            )
                .setAudioAttributes(ringtoneAttributes())
                .setOnAudioFocusChangeListener { change ->
                    Log.i(TAG, "Audio focus changed: callId=$callId change=$change")
                }
                .setAcceptsDelayedFocusGain(false)
                .setWillPauseWhenDucked(false)
                .build()

            val result = manager.requestAudioFocus(request)
            audioFocus[callId] = FocusEntry(manager, request)
            Log.i(TAG, "Audio focus request: callId=$callId result=$result")

            if (result != AudioManager.AUDIOFOCUS_REQUEST_GRANTED) {
                Log.w(TAG, "Audio focus not granted: callId=$callId")
            }
        } catch (error: Exception) {
            Log.e(TAG, "Audio focus request failed: callId=$callId", error)
        }
    }

    private fun abandonAudioFocus(callId: String) {
        audioFocus.remove(callId)?.let { entry ->
            runCatching {
                entry.manager.abandonAudioFocusRequest(entry.request)
            }.onFailure {
                Log.w(TAG, "Could not abandon audio focus: callId=$callId", it)
            }
        }
    }

    @Synchronized
    fun startIncomingRingtone(context: Context, callId: String) {
        if (callId.isBlank()) return
        stop(callId)

        val uri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
            ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION)

        if (uri == null) {
            Log.e(TAG, "No default ringtone URI: callId=$callId")
            return
        }

        requestAudioFocus(context, callId)
        val player = MediaPlayer()

        try {
            player.setAudioAttributes(ringtoneAttributes())
            player.isLooping = true
            player.setDataSource(context.applicationContext, uri)
            incomingPlayers[callId] = player

            player.setOnPreparedListener { prepared ->
                synchronized(this) {
                    if (incomingPlayers[callId] === prepared) {
                        runCatching {
                            prepared.start()
                            Log.i(TAG, "Incoming ringtone started: callId=$callId")
                        }.onFailure { error ->
                            Log.e(TAG, "Incoming ringtone start failed: callId=$callId", error)
                            incomingPlayers.remove(callId)
                            runCatching { prepared.release() }
                            abandonAudioFocus(callId)
                        }
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
                    abandonAudioFocus(callId)
                }
                Log.e(TAG, "Incoming ringtone playback failed: $what/$extra callId=$callId")
                true
            }

            player.prepareAsync()
            Log.i(TAG, "Incoming ringtone preparation started: callId=$callId")
        } catch (error: Exception) {
            incomingPlayers.remove(callId)
            runCatching { player.release() }
            abandonAudioFocus(callId)
            Log.e(TAG, "Could not start incoming ringtone: callId=$callId", error)
        }
    }

    @Synchronized
    fun startOutgoingRingback(context: Context, callId: String) {
        if (callId.isBlank()) return
        stop(callId)
        requestAudioFocus(context, callId)

        try {
            val tone = ToneGenerator(AudioManager.STREAM_RING, 80)
            outgoingTones[callId] = tone

            if (tone.startTone(ToneGenerator.TONE_SUP_RINGTONE, 60_000)) {
                Log.i(TAG, "Outgoing ringback started: callId=$callId")
            } else {
                outgoingTones.remove(callId)
                runCatching { tone.release() }
                abandonAudioFocus(callId)
                Log.e(TAG, "Android rejected outgoing ringback: callId=$callId")
            }
        } catch (error: Exception) {
            outgoingTones.remove(callId)?.let {
                runCatching { it.release() }
            }
            abandonAudioFocus(callId)
            Log.e(TAG, "Could not start outgoing ringback: callId=$callId", error)
        }
    }

    @Synchronized
    fun stop(callId: String) {
        if (callId.isBlank()) return

        incomingPlayers.remove(callId)?.let { player ->
            runCatching { if (player.isPlaying) player.stop() }
            runCatching { player.reset() }
            runCatching { player.release() }
        }

        outgoingTones.remove(callId)?.let { tone ->
            runCatching { tone.stopTone() }
            runCatching { tone.release() }
        }

        abandonAudioFocus(callId)
        Log.i(TAG, "Call audio stopped: callId=$callId")
    }
}
