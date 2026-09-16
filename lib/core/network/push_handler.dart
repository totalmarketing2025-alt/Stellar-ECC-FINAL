import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

import '../crypto/session_manager.dart';
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
    required this.sessionManager,
    required this.getLocalNickname,
  });

  final RelayClient relayClient;
  final FirebaseMessaging messaging;
  final DirectoryClient directoryClient;
  final SessionManager sessionManager;
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

  Future<void> _registerCurrentTokenWithRetry() async {
    final token = await messaging.getToken();
    if (token != null && token.isNotEmpty) {
      await _registerTokenWithRetry(token);
    }
  }

  Future<void> _registerTokenWithRetry(String token) async {
    Object? lastError;
    StackTrace? lastStack;

    for (var attempt = 0; attempt < 5; attempt++) {
      try {
        await _registerToken(token);
        return;
      } catch (error, stack) {
        lastError = error;
        lastStack = stack;

        if (attempt == 4) {
          break;
        }

        await Future<void>.delayed(Duration(seconds: 1 << attempt));
      }
    }

    if (lastError != null && lastStack != null) {
      Error.throwWithStackTrace(lastError, lastStack);
    }
  }

  Future<void> _registerToken(String token) async {
    final nicknameRaw = await getLocalNickname();
    final nickname = nicknameRaw?.trim();

    if (nickname == null || nickname.isEmpty) {
      throw const DirectoryException(
        'Local nickname is not available for push registration',
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
        'Unsupported platform for push registration',
        0,
      );
    }

    final bundle = await sessionManager.buildLocalDirectoryBundle();

    final registrationId = bundle['registrationId'];
    final deviceId = bundle['deviceId'];

    if (registrationId is! int || deviceId is! int) {
      throw const FormatException(
        'Invalid local Signal bundle identity fields',
      );
    }

    final identityKeyPair = await sessionManager.identityStore
        .getIdentityKeyPair();

    final challenge = await directoryClient.getPushChallenge(
      nickname: nickname,
    );

    final message = DirectoryClient.buildPushAuthMessage(
      nickname: nickname,
      deviceId: deviceId,
      registrationId: registrationId,
      platform: platform,
      token: token,
      challenge: challenge,
    );

    final signature = Curve.calculateSignature(
      identityKeyPair.getPrivateKey(),
      Uint8List.fromList(utf8.encode(message)),
    );

    await directoryClient.registerPushToken(
      nickname: nickname,
      token: token,
      platform: platform,
      challenge: challenge,
      signature: base64Encode(signature),
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
