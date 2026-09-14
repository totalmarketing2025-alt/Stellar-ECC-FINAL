import 'dart:io';

import 'package:firebase_messaging/firebase_messaging.dart';

import '../network/directory_client.dart';
import '../network/relay_client.dart';

/// FCM is used only as a generic wake signal.
/// No sender, chat, message text, ciphertext, or delivery token is sent
/// through FCM.
class PushHandler {
  PushHandler({
    required this.relayClient,
    required this.messaging,
    required this.directoryClient,
    required this.getLocalNickname,
  });

  final RelayClient relayClient;
  final FirebaseMessaging messaging;
  final DirectoryClient directoryClient;
  final Future<String?> Function() getLocalNickname;

  Future<void> initialize() async {
    final settings = await messaging.requestPermission(
      alert: true,
      badge: true,
      sound: false,
    );

    if (settings.authorizationStatus == AuthorizationStatus.denied) {
      return;
    }

    final token = await messaging.getToken();
    if (token != null) {
      await _registerToken(token);
    }

    messaging.onTokenRefresh.listen(_registerToken);

    FirebaseMessaging.onMessage.listen((_) => _handleWake());
    FirebaseMessaging.onMessageOpenedApp.listen((_) => _handleWake());

    final initialMessage = await messaging.getInitialMessage();
    if (initialMessage != null) {
      await _handleWake();
    }

    FirebaseMessaging.onBackgroundMessage(_backgroundHandler);
  }

  Future<void> registerCurrentToken() async {
    final token = await messaging.getToken();
    if (token != null) {
      await _registerToken(token);
    }
  }

  Future<void> _registerToken(String token) async {
    final nickname = await getLocalNickname();
    if (nickname == null || nickname.trim().isEmpty) {
      return;
    }

    final platform = Platform.isAndroid
        ? 'android'
        : Platform.isIOS
            ? 'ios'
            : 'unknown';

    if (platform == 'unknown') {
      return;
    }

    await directoryClient.registerPushToken(
      nickname: nickname,
      token: token,
      platform: platform,
    );
  }

  Future<void> _handleWake() async {
    final nickname = await getLocalNickname();
    if (nickname == null || nickname.trim().isEmpty) {
      return;
    }

    if (!relayClient.isConnected) {
      await relayClient.connect(peer: nickname);
    }
  }
}

/// Runs in a separate isolate when the app is fully backgrounded.
/// The push remains a wake signal only.
@pragma('vm:entry-point')
Future<void> _backgroundHandler(RemoteMessage message) async {}
