import 'dart:convert';
import 'dart:io';

/// Client-side contract for Stellar's Directory service.
///
/// The Directory stores public routing/Signal material only.
/// Private identity keys and session state never leave the device.
class DirectoryClient {
  DirectoryClient({
    required this.baseUrl,
    this.bearerToken,
  });

  final String baseUrl;
  final String? bearerToken;

  Future<bool> checkAvailability(String nickname) async {
    final response = await _request(
      method: 'GET',
      path: '/v1/nickname/${Uri.encodeComponent(nickname)}',
    );

    if (response.statusCode == 404) {
      return true;
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw DirectoryException(
        'Nickname availability check failed',
        response.statusCode,
      );
    }

    final bodyText = await _readBody(response);
    final body = _decodeJson(bodyText);
    return body['available'] == true;
  }

  Future<void> register({
    required String nickname,
    required Map<String, dynamic> preKeyBundle,
  }) async {
    final response = await _request(
      method: 'POST',
      path: '/v1/register',
      body: <String, dynamic>{
        'nickname': nickname,
        'bundle': preKeyBundle,
      },
    );

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw DirectoryException(
        'Directory registration failed',
        response.statusCode,
      );
    }
  }

  Future<DirectoryUserBundle> lookupBundle(String nickname) async {
    final json = await lookup(nickname);
    return DirectoryUserBundle.fromJson(json);
  }

  Future<Map<String, dynamic>> lookup(String nickname) async {
    final response = await _request(
      method: 'GET',
      path: '/v1/users/${Uri.encodeComponent(nickname)}',
    );

    if (response.statusCode == 404) {
      throw DirectoryException('User not found: $nickname', 404);
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw DirectoryException(
        'Directory lookup failed',
        response.statusCode,
      );
    }

    final body = await _readBody(response);
    return _decodeJson(body);
  }

  Future<HttpClientResponse> _request({
    required String method,
    required String path,
    Map<String, dynamic>? body,
  }) async {
    final client = HttpClient();

    try {
      final uri = Uri.parse(baseUrl).resolve(path);
      final request = await client.openUrl(method, uri);

      request.headers.set(
        HttpHeaders.acceptHeader,
        'application/json',
      );

      if (bearerToken != null && bearerToken!.isNotEmpty) {
        request.headers.set(
          HttpHeaders.authorizationHeader,
          'Bearer $bearerToken',
        );
      }

      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body));
      }

      final response = await request.close();
      return response;
    } finally {
      // The response owns the connection lifecycle after close().
    }
  }

  Future<String> _readBody(HttpClientResponse response) async {
    return await utf8.decoder.bind(response).join();
  }

  Map<String, dynamic> _decodeJson(String body) {
    final decoded = jsonDecode(body);

    if (decoded is! Map<String, dynamic>) {
      throw const FormatException(
        'Directory response must be a JSON object',
      );
    }

    return decoded;
  }
}


class DirectoryUserBundle {
  const DirectoryUserBundle({
    required this.nickname,
    required this.registrationId,
    required this.deviceId,
    required this.identityKey,
    required this.signedPreKeyId,
    required this.signedPreKey,
    required this.signedPreKeySignature,
    this.preKeyId,
    this.preKey,
  });

  final String nickname;
  final int registrationId;
  final int deviceId;

  /// Serialized Signal identity public key, encoded as base64 by Directory.
  final String identityKey;

  final int signedPreKeyId;

  /// Serialized signed-prekey public key, encoded as base64.
  final String signedPreKey;

  /// Signature over the signed prekey, encoded as base64.
  final String signedPreKeySignature;

  /// Optional one-time prekey.
  final int? preKeyId;

  /// Serialized one-time prekey public key, encoded as base64.
  final String? preKey;

  factory DirectoryUserBundle.fromJson(Map<String, dynamic> json) {
    final bundle = json['bundle'];

    if (bundle is! Map<String, dynamic>) {
      throw const FormatException('Directory response is missing bundle');
    }

    final identityKey = bundle['identityKey'];
    final signedPreKey = bundle['signedPreKey'];
    final preKey = bundle['preKey'];

    if (identityKey is! String ||
        signedPreKey is! Map<String, dynamic>) {
      throw const FormatException('Invalid Signal bundle');
    }

    final signedPreKeyId = signedPreKey['keyId'];
    final signedPreKeyPublicKey = signedPreKey['publicKey'];
    final signedPreKeySignature = signedPreKey['signature'];

    if (signedPreKeyId is! int ||
        signedPreKeyPublicKey is! String ||
        signedPreKeySignature is! String) {
      throw const FormatException('Invalid signed prekey');
    }

    int? preKeyId;
    String? preKeyPublicKey;

    if (preKey != null) {
      if (preKey is! Map<String, dynamic>) {
        throw const FormatException('Invalid prekey');
      }

      if (preKey['keyId'] is! int || preKey['publicKey'] is! String) {
        throw const FormatException('Invalid one-time prekey');
      }

      preKeyId = preKey['keyId'] as int;
      preKeyPublicKey = preKey['publicKey'] as String;
    }

    final registrationId = bundle['registrationId'];
    final deviceId = bundle['deviceId'];

    if (registrationId is! int || deviceId is! int) {
      throw const FormatException('Invalid registration/device id');
    }

    final nickname = json['nickname'];

    if (nickname is! String || nickname.isEmpty) {
      throw const FormatException('Invalid directory nickname');
    }

    return DirectoryUserBundle(
      nickname: nickname,
      registrationId: registrationId,
      deviceId: deviceId,
      identityKey: identityKey,
      signedPreKeyId: signedPreKeyId,
      signedPreKey: signedPreKeyPublicKey,
      signedPreKeySignature: signedPreKeySignature,
      preKeyId: preKeyId,
      preKey: preKeyPublicKey,
    );
  }
}

class DirectoryException implements Exception {
  const DirectoryException(this.message, this.statusCode);

  final String message;
  final int statusCode;

  @override
  String toString() => 'DirectoryException($statusCode): $message';
}
