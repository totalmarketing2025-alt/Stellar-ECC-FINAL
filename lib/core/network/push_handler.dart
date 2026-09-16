import 'dart:async';
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

    unawaited(_registerCurrentTokenWithRetry());

    messaging.onTokenRefresh.listen(
      (token) => unawaited(_registerTokenWithRetry(token)),
    );

    FirebaseMessaging.onMessage.listen((_) => _handleWake());
    FirebaseMessaging.onMessageOpenedApp.listen((_) => _handleWake());

    final initialMessage = await messaging.getInitialMessage();
    if (initialMessage != null) {
      await _handleWake();
    }

    FirebaseMessaging.onBackgroundMessage(_backgroundHandler);
  }

  Future<void> registerCurrentToken() async {
    await _registerCurrentTokenWithRetry();
  }

  Future<void> _registerCurrentTokenWithRetry([String? refreshedToken]) async {
    String? token = refreshedToken;

    for (var attempt = 0; attempt < 5; attempt++) {
      try {
        token ??= await messaging.getToken();

        if (token == null || token!.trim().isEmpty) {
          token = null;
        } else {
          await _registerToken(token!);
          return;
        }
      } catch (_) {
        // Retry below. Startup/token rotation must not fail permanently
        // because Firebase or Directory is temporarily unavailable.
      }

      if (attempt < 4) {
        await Future.delayed(Duration(seconds: 1 << attempt));
      }
    }
  }

  Future<void> _registerToken(String token) async {
    final nickname = await getLocalNickname();
    if (nickname == null || nickname.trim().isEmpty) {
      throw const DirectoryException(
        'Local nickname is not available yet',
        0,
      );
    }

    final platform = Platform.isAndroid
        ? 'android'
        : Platform.isIOS
            ? 'ios'
            : 'unknown';

    if (platform == 'unknown') {
      throw const DirectoryException(
        'Unsupported push platform',
        0,
      );
    }

    await directoryClient.registerPushToken(
      nickname: nickname.trim(),
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
