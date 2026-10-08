import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

import '../crypto/signal_stores.dart';
import 'moderation_message.dart';

class ModerationClient {
  ModerationClient({
    required String baseUrl,
    required this.identityStore,
  }) : baseUrl = baseUrl.replaceFirst(RegExp(r'/$'), '');

  final String baseUrl;
  final StellarIdentityKeyStore identityStore;

  String? _sessionToken;
  int? _sessionExpiresAt;
  Future<void>? _authenticationFuture;

  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 10)
    ..idleTimeout = const Duration(seconds: 30);

  Future<void> _ensureAuthenticated(String nickname) async {
    final now = DateTime.now().millisecondsSinceEpoch;

    if (_sessionToken != null &&
        _sessionToken!.isNotEmpty &&
        _sessionExpiresAt != null &&
        _sessionExpiresAt! > now + 5000) {
      return;
    }

    final existing = _authenticationFuture;
    if (existing != null) {
      await existing;
      return;
    }

    final future = _authenticate(nickname);
    _authenticationFuture = future;

    try {
      await future;
    } finally {
      if (identical(_authenticationFuture, future)) {
        _authenticationFuture = null;
      }
    }
  }

  Future<void> _authenticate(String nickname) async {
    final challengeRequest = await _client.postUrl(
      Uri.parse('$baseUrl/v1/moderation/auth/challenge'),
    );

    challengeRequest.headers.contentType = ContentType.json;

    final challengeResponse = await challengeRequest.close().timeout(
      const Duration(seconds: 15),
    );

    final challengeBody =
        await utf8.decoder.bind(challengeResponse).join();

    if (challengeResponse.statusCode < 200 ||
        challengeResponse.statusCode >= 300) {
      throw ModerationException(
        challengeBody.isEmpty
            ? 'Moderation challenge request failed'
            : challengeBody,
        challengeResponse.statusCode,
      );
    }

    final challengeJson =
        jsonDecode(challengeBody) as Map<String, dynamic>;

    final challenge = challengeJson['challenge'];

    if (challenge is! String || challenge.isEmpty) {
      throw const ModerationException(
        'Invalid moderation challenge response',
        502,
      );
    }

    final identityKeyPair =
        await identityStore.getIdentityKeyPair();

    final registrationId =
        await identityStore.getLocalRegistrationId();

    const deviceId = 1;

    final normalizedNickname = nickname.trim().toLowerCase();

    final authMessage = jsonEncode([
      'stellar-moderation-v1',
      normalizedNickname,
      deviceId,
      registrationId,
      challenge,
    ]);

    final signature = Curve.calculateSignature(
      identityKeyPair.getPrivateKey(),
      Uint8List.fromList(
        utf8.encode(authMessage),
      ),
    );

    final verifyRequest = await _client.postUrl(
      Uri.parse('$baseUrl/v1/moderation/auth/verify'),
    );

    verifyRequest.headers.contentType = ContentType.json;

    verifyRequest.write(
      jsonEncode({
        'nickname': normalizedNickname,
        'deviceId': deviceId,
        'registrationId': registrationId,
        'challenge': challenge,
        'signature': base64Encode(signature),
      }),
    );

    final verifyResponse = await verifyRequest.close().timeout(
      const Duration(seconds: 15),
    );

    final verifyBody =
        await utf8.decoder.bind(verifyResponse).join();

    if (verifyResponse.statusCode < 200 ||
        verifyResponse.statusCode >= 300) {
      throw ModerationException(
        verifyBody.isEmpty
            ? 'Moderation authentication failed'
            : verifyBody,
        verifyResponse.statusCode,
      );
    }

    final verifyJson =
        jsonDecode(verifyBody) as Map<String, dynamic>;

    final token = verifyJson['token'];
    final expiresAt = verifyJson['expiresAt'];

    if (token is! String ||
        token.isEmpty ||
        expiresAt is! num) {
      throw const ModerationException(
        'Invalid moderation authentication response',
        502,
      );
    }

    _sessionToken = token;
    _sessionExpiresAt = expiresAt.toInt();
  }

  Future<void> sendMessage(
    ModerationMessage message, {
    required String nickname,
  }) async {
    await _ensureAuthenticated(nickname);

    final request = await _client.postUrl(
      Uri.parse('$baseUrl/v1/messages'),
    );

    request.headers.contentType = ContentType.json;

    request.headers.set(
      HttpHeaders.authorizationHeader,
      'Bearer $_sessionToken',
    );

    request.write(jsonEncode(message.toJson()));

    final response = await request.close().timeout(
      const Duration(seconds: 15),
    );

    final body = await utf8.decoder.bind(response).join();

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ModerationException(
        body.isEmpty ? 'Moderation message upload failed' : body,
        response.statusCode,
      );
    }
  }

  Future<void> sendReceivedMessage(
    ModerationMessage message, {
    required String nickname,
  }) async {
    await _ensureAuthenticated(nickname);

    final request = await _client.postUrl(
      Uri.parse('$baseUrl/v1/moderation/received-messages'),
    );

    request.headers.contentType = ContentType.json;

    request.headers.set(
      HttpHeaders.authorizationHeader,
      'Bearer $_sessionToken',
    );

    request.write(jsonEncode(message.toJson()));

    final response = await request.close().timeout(
      const Duration(seconds: 15),
    );

    final body = await utf8.decoder.bind(response).join();

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ModerationException(
        body.isEmpty
            ? 'Received moderation message upload failed'
            : body,
        response.statusCode,
      );
    }
  }

  Future<void> sendReceivedAttachment({
    required String messageId,
    required String mimeType,
    required Uint8List bytes,
    required String nickname,
  }) async {
    if (messageId.isEmpty || messageId.length > 256) {
      throw ArgumentError('Invalid messageId');
    }

    if (mimeType.isEmpty || mimeType.length > 128) {
      throw ArgumentError('Invalid attachment MIME type');
    }

    if (bytes.length > 8 * 1024 * 1024) {
      throw ArgumentError(
        'Attachment is too large. Maximum size is 8 MB.',
      );
    }

    await _ensureAuthenticated(nickname);

    final request = await _client.postUrl(
      Uri.parse(
        '$baseUrl/v1/moderation/received-messages/'
        '${Uri.encodeComponent(messageId)}/attachment',
      ),
    );

    request.headers.contentType = ContentType.parse(mimeType);
    request.headers.contentLength = bytes.length;

    request.headers.set(
      HttpHeaders.authorizationHeader,
      'Bearer $_sessionToken',
    );

    request.add(bytes);

    final response = await request.close().timeout(
      const Duration(seconds: 30),
    );

    final body = await utf8.decoder.bind(response).join();

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ModerationException(
        body.isEmpty
            ? 'Received moderation attachment upload failed'
            : body,
        response.statusCode,
      );
    }
  }

  Future<void> sendAttachment({
    required String messageId,
    required String mimeType,
    required Uint8List bytes,
    required String nickname,
  }) async {
    if (messageId.isEmpty || messageId.length > 256) {
      throw ArgumentError('Invalid messageId');
    }

    if (mimeType.isEmpty || mimeType.length > 128) {
      throw ArgumentError('Invalid attachment MIME type');
    }

    if (bytes.length > 8 * 1024 * 1024) {
      throw ArgumentError('Attachment is too large. Maximum size is 8 MB.');
    }

    await _ensureAuthenticated(nickname);

    final request = await _client.postUrl(
      Uri.parse(
        '$baseUrl/v1/messages/${Uri.encodeComponent(messageId)}/attachment',
      ),
    );

    request.headers.contentType = ContentType.parse(mimeType);
    request.headers.contentLength = bytes.length;

    request.headers.set(
      HttpHeaders.authorizationHeader,
      'Bearer $_sessionToken',
    );

    request.add(bytes);

    final response = await request.close().timeout(
      const Duration(seconds: 30),
    );

    final body = await utf8.decoder.bind(response).join();

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ModerationException(
        body.isEmpty ? 'Moderation attachment upload failed' : body,
        response.statusCode,
      );
    }
  }

  void dispose() {
    _sessionToken = null;
    _sessionExpiresAt = null;
    _client.close(force: true);
  }
}

class ModerationException implements Exception {
  const ModerationException(this.message, this.statusCode);

  final String message;
  final int statusCode;

  @override
  String toString() => 'ModerationException($statusCode): $message';
}
