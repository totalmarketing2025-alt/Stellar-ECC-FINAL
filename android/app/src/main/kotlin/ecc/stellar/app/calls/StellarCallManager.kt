package ecc.stellar.app.calls

import android.content.ComponentName
import android.content.Intent
import android.content.Context
import android.net.Uri
import android.os.Bundle
import android.os.Build
import android.telecom.Connection
import android.telecom.ConnectionRequest
import android.telecom.ConnectionService
import android.telecom.PhoneAccount
import android.telecom.PhoneAccountHandle
import android.telecom.TelecomManager
import android.telecom.VideoProfile

object StellarCallManager {

    const val EXTRA_CALL_ID = "stellar.call.id"
    const val EXTRA_REMOTE_NICKNAME = "stellar.call.remote"
    const val EXTRA_CALL_KIND = "stellar.call.kind"
    const val EXTRA_CHAT_ID = "stellar.call.chat"

    private const val PHONE_ACCOUNT_ID = "stellar_voip"

    private val activeConnections =
        mutableMapOf<String, StellarConnection>()

    fun registerConnection(
        callId: String,
        connection: StellarConnection
    ) {
        if (callId.isBlank()) return
        StellarCallManager.registerConnection(callId, connection)
    }

    fun setCallActive(callId: String): Boolean {
        val connection = activeConnections[callId] ?: return false
        connection.setActive()
        return true
    }

    fun setCallEnded(callId: String): Boolean {
        val connection = activeConnections.remove(callId) ?: return false
        connection.setDisconnected(
            Connection.DisconnectCause(Connection.DisconnectCause.REMOTE)
        )
        connection.destroy()
        return true
    }

    fun removeConnection(callId: String) {
        activeConnections.remove(callId)
    }

    fun handle(context: Context): PhoneAccountHandle =
        PhoneAccountHandle(
            ComponentName(context, StellarConnectionService::class.java),
            PHONE_ACCOUNT_ID
        )

    fun ensureRegistered(context: Context) {
        val telecom =
            context.getSystemService(Context.TELECOM_SERVICE) as TelecomManager

        val handle = handle(context)

        if (telecom.getPhoneAccount(handle) != null) {
            return
        }

        val account = PhoneAccount.builder(
            handle,
            "Stellar ECC"
        )
            .setCapabilities(PhoneAccount.CAPABILITY_SELF_MANAGED)
            .setSupportedUriSchemes(listOf("stellar"))
            .build()

        telecom.registerPhoneAccount(account)
    }

    fun incoming(
        context: Context,
        callId: String,
        remoteNickname: String,
        kind: String,
        chatId: String?
    ) {
        if (callId.isBlank() || remoteNickname.isBlank()) return
        if (kind != "voice" && kind != "video") return

        ensureRegistered(context)

        val telecom =
            context.getSystemService(Context.TELECOM_SERVICE) as TelecomManager

        val extras = Bundle().apply {
            putString(EXTRA_CALL_ID, callId)
            putString(EXTRA_REMOTE_NICKNAME, remoteNickname)
            putString(EXTRA_CALL_KIND, kind)

            if (!chatId.isNullOrBlank()) {
                putString(EXTRA_CHAT_ID, chatId)
            }

            putInt(
                TelecomManager.EXTRA_INCOMING_VIDEO_STATE,
                if (kind == "video") {
                    VideoProfile.STATE_BIDIRECTIONAL
                } else {
                    VideoProfile.STATE_AUDIO_ONLY
                }
            )
        }

        val address = Uri.parse("stellar:$callId")

        telecom.addNewIncomingCall(
            handle(context),
            Bundle().apply {
                putParcelable(
                    TelecomManager.EXTRA_INCOMING_CALL_ADDRESS,
                    address
                )
                putAll(extras)
            }
        )
    }
}

class StellarConnectionService : ConnectionService() {

    override fun onCreate() {
        super.onCreate()
        StellarCallManager.ensureRegistered(this)
    }

    override fun onCreateIncomingConnection(
        phoneAccount: PhoneAccountHandle,
        request: ConnectionRequest
    ): Connection {

        val extras = request.extras ?: Bundle()

        val callId =
            extras.getString(StellarCallManager.EXTRA_CALL_ID).orEmpty()

        val remote =
            extras.getString(
                StellarCallManager.EXTRA_REMOTE_NICKNAME
            ).orEmpty()

        val kind =
            extras.getString(
                StellarCallManager.EXTRA_CALL_KIND
            ) ?: "voice"

        val connection = StellarConnection(this)

        activeConnections[callId] = connection

        connection.callId = callId
        connection.remoteNickname = remote
        connection.kind = kind
        connection.chatId =
            extras.getString(StellarCallManager.EXTRA_CHAT_ID).orEmpty()

        connection.setConnectionProperties(
            Connection.PROPERTY_SELF_MANAGED
        )

        connection.setConnectionCapabilities(
            Connection.CAPABILITY_MUTE
        )

        connection.setAudioModeIsVoip(true)

        connection.setCallerDisplayName(
            if (remote.isBlank()) "Stellar ECC" else remote,
            Connection.PRESENTATION_ALLOWED
        )

        connection.setAddress(
            Uri.parse("stellar:$callId"),
            Connection.PRESENTATION_ALLOWED
        )

        connection.setVideoState(
            if (kind == "video") {
                VideoProfile.STATE_BIDIRECTIONAL
            } else {
                VideoProfile.STATE_AUDIO_ONLY
            }
        )

        connection.setRinging()

        StellarIncomingCallNotification.show(
            this,
            callId,
            remote,
            kind
        )

        return connection
    }

    fun setCallActive(callId: String): Boolean {
        val connection = activeConnections[callId] ?: return false
        connection.setActive()
        return true
    }

    fun setCallEnded(callId: String): Boolean {
        val connection = activeConnections.remove(callId) ?: return false
        connection.setDisconnected(
            Connection.DisconnectCause(Connection.DisconnectCause.REMOTE)
        )
        connection.destroy()
        return true
    }

    fun removeConnection(callId: String) {
        activeConnections.remove(callId)
    }
}

class StellarConnection(
    private val appContext: Context
) : Connection() {

    var callId = ""
    var remoteNickname = ""
    var kind = "voice"
    var chatId = ""

    override fun onAnswer() {
        val foregroundIntent = Intent(
            appContext,
            StellarCallForegroundService::class.java,
        ).apply {
            action = StellarCallForegroundService.ACTION_START
            putExtra(
                StellarCallForegroundService.EXTRA_CALL_ID,
                callId,
            )
            putExtra(
                StellarCallForegroundService.EXTRA_REMOTE_NICKNAME,
                remoteNickname,
            )
            putExtra(
                StellarCallForegroundService.EXTRA_CALL_KIND,
                kind,
            )
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            appContext.startForegroundService(foregroundIntent)
        } else {
            appContext.startService(foregroundIntent)
        }

        StellarIncomingCallNotification.cancel(
            appContext,
            callId,
        )

        StellarIncomingCallActivity.launchAction(
            appContext,
            "answer",
            callId,
            remoteNickname,
            kind,
            chatId,
        )
    }

    override fun onReject() {
        setDisconnected(
            Connection.DisconnectCause(Connection.DisconnectCause.REJECTED),
        )

        stopForegroundCallService()

        StellarIncomingCallNotification.cancel(
            appContext,
            callId,
        )

        StellarIncomingCallActivity.launchAction(
            appContext,
            "reject",
            callId,
            remoteNickname,
            kind,
            chatId,
        )

        StellarCallManager.removeConnection(callId)
        destroy()
    }

    override fun onDisconnect() {
        setDisconnected(
            Connection.DisconnectCause(Connection.DisconnectCause.LOCAL),
        )

        stopForegroundCallService()

        StellarIncomingCallNotification.cancel(
            appContext,
            callId,
        )

        StellarIncomingCallActivity.launchAction(
            appContext,
            "end",
            callId,
            remoteNickname,
            kind,
            chatId,
        )

        StellarCallManager.removeConnection(callId)
        destroy()
    }

    private fun stopForegroundCallService() {
        val intent = Intent(
            appContext,
            StellarCallForegroundService::class.java,
        ).apply {
            action = StellarCallForegroundService.ACTION_STOP
        }

        appContext.startService(intent)
    }
}
