package ecc.stellar.app

import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage

/**
 * Per Phase 4 §4 / Phase 9 §9.3: the push payload sent by our relay's push
 * bridge is data-only, with no alert/title/body and no sender or chat
 * identifier. This service's only job is to wake the process; the actual
 * "you have a new message" UI is rendered locally, after the app has
 * reconnected to the relay and fetched the (still end-to-end encrypted)
 * envelope over the WebSocket — never from anything in the push payload
 * itself.
 */
class StellarFirebaseMessagingService : FirebaseMessagingService() {

    override fun onMessageReceived(remoteMessage: RemoteMessage) {
        super.onMessageReceived(remoteMessage)
        // Intentionally does not read remoteMessage.notification or any
        // content field — wakes the Flutter engine's background work via
        // the plugin's registered background handler, which reconnects to
        // the relay and lets the existing WebSocket flow take over.
    }

    override fun onNewToken(token: String) {
        super.onNewToken(token)
        // Forwarded to the directory server as route_id -> token only,
        // never linked to nickname/identity server-side (Phase 4 §4).
    }
}
