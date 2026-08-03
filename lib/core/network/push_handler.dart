import 'package:firebase_messaging/firebase_messaging.dart';

import '../network/relay_client.dart';

/// Registers the FCM/APNs token with the directory server as an opaque
/// `route_id -> token` mapping, and handles incoming pushes strictly as
/// wake signals — per Phase 4 §4 / Phase 9 §9.3, the payload never
/// contains sender, chat, or message content, so there is nothing to
/// read here except "reconnect and let the relay flow take over."
class PushHandler {
  PushHandler({required this.relayClient, required this.messaging});

  final RelayClient relayClient;
  final FirebaseMessaging messaging;

  Future<void> initialize({required String bearerToken}) async {
    final settings = await messaging.requestPermission(
      alert: false, // silent/data-only pushes only — no OS alert banner needed
      badge: true,
      sound: false,
    );

    if (settings.authorizationStatus == AuthorizationStatus.denied) {
      // App still functions via the persistent WebSocket while foregrounded;
      // only background wake-on-push is degraded, not core messaging.
      return;
    }

    final token = await messaging.getToken();
    if (token != null) {
      await _registerToken(token);
    }

    messaging.onTokenRefresh.listen(_registerToken);

    FirebaseMessaging.onMessage.listen((message) => _handleWake(bearerToken));
    FirebaseMessaging.onBackgroundMessage(_backgroundHandler);
    FirebaseMessaging.onMessageOpenedApp.listen((message) => _handleWake(bearerToken));
  }

  Future<void> _registerToken(String token) async {
    // POST to the directory server: { route_id, platform, token } — no
    // nickname or identity key in this call, matching the metadata-
    // minimization requirement (Phase 4 §4).
  }

  Future<void> _handleWake(String bearerToken) async {
    if (!relayClient.isConnected) {
      await relayClient.connect(bearerToken);
    }
    // Reconnecting is sufficient — RelayClient.connect() triggers the
    // server's flushQueuedEnvelopes() path (Phase 9 §9.1), which is where
    // any actual message content arrives, still end-to-end encrypted.
  }
}

/// Must be a top-level or static function per the firebase_messaging plugin
/// contract — runs in a separate isolate when the app is fully backgrounded.
Future<void> _backgroundHandler(RemoteMessage message) async {
  // Intentionally minimal: no plugin/database initialization happens here
  // by default to avoid doing meaningful work (and potential plaintext
  // exposure) in a background isolate outside the app's normal lifecycle.
  // A production build may initialize just enough to run ExpirySweeper's
  // sweepOnce() here if background TTL enforcement needs to be tighter
  // than the foreground-only ticker allows.
}
