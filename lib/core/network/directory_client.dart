import 'dart:convert';
import 'dart:io';


import 'directory_user_bundle.dart';

class DirectoryClient {
  DirectoryClient({required String baseUrl, this.bearerToken})
    : baseUrl = baseUrl.replaceFirst(RegExp(r'/$'), '');

  final String baseUrl;
  final String? bearerToken;

  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 10)
    ..idleTimeout = const Duration(seconds: 30);

  static String buildPushAuthMessage({
    required String nickname,
    required int deviceId,
    required int registrationId,
    required String platform,
    required String token,
    required String challenge,
  }) {
    return jsonEncode([
      'stellar-push-v1',
      nickname,
      deviceId,
      registrationId,
      platform,
      token,
      challenge,
    ]);
  }

  static String buildRelayAuthMessage({
    required String nickname,
    required int deviceId,
    required int registrationId,
    required String challenge,
  }) {
    return jsonEncode([
      'stellar-relay-v1',
      nickname,
      deviceId,
      registrationId,
      challenge,
    ]);
  }

  // Guard uses the same registered Signal identity as relay and profile
  // operations. The caller signs the canonical, action-bound message before
  // making the proof request; these routes never authorize deletion.
  Future<String> getGuardAccountChallenge({
    required String nickname,
    required int deviceId,
    required int registrationId,
  }) async => _guardChallenge(await _guardPost(
    '/v1/guard/account/challenge',
    {'nickname': nickname, 'deviceId': deviceId,
      'registrationId': registrationId},
  ));

  Future<bool> getGuardAccountRevocation({
    required String nickname,
    required int deviceId,
    required int registrationId,
    required String challenge,
    required String signature,
  }) async {
    final response = await _guardPost('/v1/guard/account/status', {
      'nickname': nickname,
      'deviceId': deviceId,
      'registrationId': registrationId,
      'challenge': challenge,
      'signature': signature,
    });
    if (response['revoked'] is! bool ||
        !['active', 'revoked'].contains(response['status']) ||
        response['revoked'] != (response['status'] == 'revoked')) {
      throw const FormatException('Invalid Guard account status');
    }
    return response['revoked'] as bool;
  }

  Future<String> getGuardIdentityChallenge({
    required String nickname,
    required int deviceId,
    required int registrationId,
  }) async {
    final data = await _guardPost('/v1/guard/code/challenge', {
      'nickname': nickname,
      'deviceId': deviceId,
      'registrationId': registrationId,
    });
    return _guardChallenge(data);
  }

  Future<String> getOwnGuardCode({
    required String nickname,
    required int deviceId,
    required int registrationId,
    required String challenge,
    required String signature,
  }) async {
    final data = await _guardPost('/v1/guard/code', {
      'nickname': nickname,
      'deviceId': deviceId,
      'registrationId': registrationId,
      'challenge': challenge,
      'signature': signature,
    });
    final code = data['guardCode'];
    if (code is! String || !RegExp(r'^[0-9]{9}$').hasMatch(code)) {
      throw const FormatException('Invalid nine-digit Guard code response');
    }
    return code;
  }

  Future<String> getGuardCaseChallenge({
    required String nickname,
    required int deviceId,
    required int registrationId,
    required String purpose,
  }) async {
    final data = await _guardPost('/v1/guard/cases/challenge', {
      'nickname': nickname,
      'deviceId': deviceId,
      'registrationId': registrationId,
      'purpose': purpose,
    });
    return _guardChallenge(data);
  }

  Future<Map<String, dynamic>> submitGuardCase(Map<String, dynamic> proof) =>
      _guardPost('/v1/guard/cases', proof);

  Future<Map<String, dynamic>> getGuardCaseStatus({
    required String caseId,
    required Map<String, dynamic> proof,
  }) => _guardPost('/v1/guard/cases/${Uri.encodeComponent(caseId)}/status', proof);

  Future<Map<String, dynamic>> cancelGuardCase({
    required String caseId,
    required Map<String, dynamic> proof,
  }) => _guardPost('/v1/guard/cases/${Uri.encodeComponent(caseId)}/cancel', proof);

  Future<Map<String, dynamic>> _guardPost(
    String path,
    Map<String, dynamic> body,
  ) async {
    final response = await _request('POST', path, body: body);
    final data = _decodeJson(
      await _readBody(response).timeout(const Duration(seconds: 15)),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw DirectoryException(
        data['error']?.toString() ?? 'Guard request failed',
        response.statusCode,
      );
    }
    return data;
  }

  String _guardChallenge(Map<String, dynamic> data) {
    final challenge = data['challenge'];
    final expiresAt = data['expiresAt'];
    if (challenge is! String || challenge.length < 20 ||
        expiresAt is! int || expiresAt <= 0) {
      throw const FormatException('Invalid or expired Guard challenge response');
    }
    return challenge;
  }

  Future<bool> checkAvailability(String nickname) async {
    final response = await _request(
      'GET',
      '/v1/nickname/${Uri.encodeComponent(nickname)}',
    );

    if (response.statusCode == 404) {
      return true;
    }

    if (response.statusCode != 200) {
      throw DirectoryException(
        'Directory availability check failed',
        response.statusCode,
      );
    }

    final body = await _readBody(response);
    final json = _decodeJson(body);

    final available = json['available'];
    if (available is! bool) {
      throw const FormatException(
        'Invalid availability response from Directory',
      );
    }

    return available;
  }

  Future<Map<String, dynamic>> register({
    required String nickname,
    required Map<String, dynamic> preKeyBundle,
  }) async {
    final response = await _request(
      'POST',
      '/v1/register',
      body: {'nickname': nickname, 'bundle': preKeyBundle},
    );

    final body = await _readBody(response);
    final json = _decodeJson(body);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw DirectoryException(
        json['error']?.toString() ?? 'Directory registration failed',
        response.statusCode,
      );
    }

    return json;
  }

  Future<Map<String, dynamic>> updateBundle({
    required String nickname,
    required Map<String, dynamic> preKeyBundle,
  }) async {
    final response = await _request(
      'PUT',
      '/v1/users/${Uri.encodeComponent(nickname)}/bundle',
      body: {'bundle': preKeyBundle},
    );

    final body = await _readBody(response);
    final json = _decodeJson(body);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw DirectoryException(
        json['error']?.toString() ?? 'Directory bundle update failed',
        response.statusCode,
      );
    }

    return json;
  }

  Future<String> getPushChallenge({
    required String nickname,
    required int deviceId,
    required int registrationId,
  }) async {
    final response = await _request(
      'POST',
      '/v1/users/${Uri.encodeComponent(nickname)}/push-token/challenge',
      body: {'deviceId': deviceId, 'registrationId': registrationId},
    );

    final body = await _readBody(response);
    final json = _decodeJson(body);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw DirectoryException(
        json['error']?.toString() ?? 'Push challenge request failed',
        response.statusCode,
      );
    }

    final challenge = json['challenge'];
    if (challenge is! String || challenge.isEmpty) {
      throw const FormatException(
        'Invalid push challenge returned by Directory',
      );
    }

    return challenge;
  }

  Future<String> getTurnChallenge({
    required String nickname,
    required int deviceId,
    required int registrationId,
  }) async {
    final response = await _request(
      'POST',
      '/v1/turn-credentials/challenge',
      body: {
        'nickname': nickname,
        'deviceId': deviceId,
        'registrationId': registrationId,
      },
    );

    final body = await _readBody(response);
    final json = _decodeJson(body);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw DirectoryException(
        json['error']?.toString() ?? 'TURN challenge request failed',
        response.statusCode,
      );
    }

    final challenge = json['challenge'];
    if (challenge is! String || challenge.isEmpty) {
      throw const FormatException(
        'Invalid TURN challenge returned by Directory',
      );
    }

    return challenge;
  }

  static String buildTurnAuthMessage({
    required String nickname,
    required int deviceId,
    required int registrationId,
    required String challenge,
  }) {
    return jsonEncode([
      'stellar-turn-v1',
      nickname,
      deviceId,
      registrationId,
      challenge,
    ]);
  }

  Future<Map<String, dynamic>> getTurnCredentials({
    required String nickname,
    required int deviceId,
    required int registrationId,
    required String challenge,
    required String signature,
  }) async {
    final response = await _request(
      'POST',
      '/v1/turn-credentials',
      body: {
        'nickname': nickname,
        'deviceId': deviceId,
        'registrationId': registrationId,
        'challenge': challenge,
        'signature': signature,
      },
    );

    final body = await _readBody(response);
    final json = _decodeJson(body);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw DirectoryException(
        json['error']?.toString() ?? 'TURN credentials request failed',
        response.statusCode,
      );
    }

    return json;
  }

  Future<Map<String, dynamic>> registerPushToken({
    required String nickname,
    required String token,
    required String platform,
    required String challenge,
    required String signature,
  }) async {
    final response = await _request(
      'PUT',
      '/v1/users/${Uri.encodeComponent(nickname)}/push-token',
      body: {
        'token': token,
        'platform': platform,
        'challenge': challenge,
        'signature': signature,
      },
    );

    final body = await _readBody(response);
    final json = _decodeJson(body);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw DirectoryException(
        json['error']?.toString() ?? 'Push token registration failed',
        response.statusCode,
      );
    }

    return json;
  }


  static String buildProfilePhotoAuthMessage({
    required String nickname,
    required int deviceId,
    required int registrationId,
    required String operation,
    required String mimeType,
    required String sha256Hex,
    required String challenge,
  }) {
    if (operation != 'put' && operation != 'delete') {
      throw ArgumentError.value(operation, 'operation');
    }

    return jsonEncode([
      'stellar-profile-photo-v1',
      nickname,
      deviceId,
      registrationId,
      operation,
      mimeType,
      sha256Hex,
      challenge,
    ]);
  }

  Future<String> getProfilePhotoChallenge({
    required String nickname,
    required int deviceId,
    required int registrationId,
    required String operation,
  }) async {
    if (operation != 'put' && operation != 'delete') {
      throw ArgumentError.value(operation, 'operation');
    }

    final response = await _request(
      'POST',
      '/v1/users/${Uri.encodeComponent(nickname)}/profile-photo/challenge',
      body: {
        'deviceId': deviceId,
        'registrationId': registrationId,
        'operation': operation,
      },
    );

    final body = await _readBody(response);
    final json = _decodeJson(body);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw DirectoryException(
        json['error']?.toString() ??
            'Profile-photo challenge request failed',
        response.statusCode,
      );
    }

    final challenge = json['challenge'];
    if (challenge is! String || challenge.length < 20) {
      throw const FormatException(
        'Invalid profile-photo challenge response',
      );
    }

    return challenge;
  }

  Future<Map<String, dynamic>?> fetchProfilePhoto(
    String nickname,
  ) async {
    final response = await _request(
      'GET',
      '/v1/users/${Uri.encodeComponent(nickname)}/profile-photo',
    );

    final body = await _readBody(response);

    if (response.statusCode == 404) {
      return null;
    }

    final json = _decodeJson(body);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw DirectoryException(
        json['error']?.toString() ?? 'Profile-photo download failed',
        response.statusCode,
      );
    }

    final encodedPhoto = json['photo'];
    final mimeType = json['mimeType'];
    final updatedAt = json['updatedAt'];

    if (encodedPhoto is! String ||
        mimeType is! String ||
        updatedAt is! num ||
        !const {'image/jpeg', 'image/png', 'image/webp'}
            .contains(mimeType)) {
      throw const FormatException(
        'Invalid profile-photo response',
      );
    }

    return {
      'nickname': json['nickname'],
      'photo': encodedPhoto,
      'mimeType': mimeType,
      'updatedAt': updatedAt,
    };
  }

  Future<void> uploadProfilePhoto({
    required String nickname,
    required int deviceId,
    required int registrationId,
    required String challenge,
    required String signature,
    required String mimeType,
    required String photoBase64,
  }) async {
    final response = await _request(
      'PUT',
      '/v1/users/${Uri.encodeComponent(nickname)}/profile-photo',
      body: {
        'deviceId': deviceId,
        'registrationId': registrationId,
        'challenge': challenge,
        'signature': signature,
        'mimeType': mimeType,
        'photo': photoBase64,
      },
    );

    final body = await _readBody(response);
    final json = _decodeJson(body);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw DirectoryException(
        json['error']?.toString() ?? 'Profile-photo upload failed',
        response.statusCode,
      );
    }
  }

  Future<void> deleteProfilePhoto({
    required String nickname,
    required int deviceId,
    required int registrationId,
    required String challenge,
    required String signature,
  }) async {
    final response = await _request(
      'DELETE',
      '/v1/users/${Uri.encodeComponent(nickname)}/profile-photo',
      body: {
        'deviceId': deviceId,
        'registrationId': registrationId,
        'challenge': challenge,
        'signature': signature,
      },
    );

    final body = await _readBody(response);
    final json = _decodeJson(body);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw DirectoryException(
        json['error']?.toString() ?? 'Profile-photo deletion failed',
        response.statusCode,
      );
    }
  }

  Future<Map<String, dynamic>> lookup(String nickname) async {
    final response = await _request(
      'GET',
      '/v1/users/${Uri.encodeComponent(nickname)}',
    );

    final body = await _readBody(response);
    final json = _decodeJson(body);

    if (response.statusCode != 200) {
      throw DirectoryException(
        json['error']?.toString() ?? 'Directory lookup failed',
        response.statusCode,
      );
    }

    return json;
  }

  Future<DirectoryUserBundle> lookupBundle(String nickname) async {
    final json = await lookup(nickname);
    return DirectoryUserBundle.fromJson(json);
  }

  Future<HttpClientResponse> _request(
    String method,
    String path, {
    Map<String, dynamic>? body,
  }) async {
    final request = await _client.openUrl(method, Uri.parse('$baseUrl$path'));

    request.headers.contentType = ContentType.json;

    if (bearerToken != null && bearerToken!.isNotEmpty) {
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer $bearerToken',
      );
    }

    if (body != null) {
      request.write(jsonEncode(body));
    }

    return request.close().timeout(const Duration(seconds: 15));
  }

  void dispose() {
    _client.close(force: true);
  }

  Future<String> _readBody(HttpClientResponse response) async {
    return utf8.decoder.bind(response).join();
  }

  Map<String, dynamic> _decodeJson(String body) {
    try {
      final decoded = jsonDecode(body);

      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Directory response must be a JSON object');
      }

      return decoded;
    } catch (_) {
      throw const FormatException('Invalid JSON returned by Directory');
    }
  }
}

class DirectoryException implements Exception {
  const DirectoryException(this.message, this.statusCode);

  final String message;
  final int statusCode;

  @override
  String toString() => 'DirectoryException($statusCode): $message';
}
