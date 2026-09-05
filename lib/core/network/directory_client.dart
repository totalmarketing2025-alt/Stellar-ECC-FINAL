import 'dart:convert';
import 'dart:io';

import 'directory_user_bundle.dart';

class DirectoryClient {
  DirectoryClient({
    required String baseUrl,
    this.bearerToken,
  }) : baseUrl = baseUrl.replaceFirst(RegExp(r'/$'), '');

  final String baseUrl;
  final String? bearerToken;

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
      body: {
        'nickname': nickname,
        'bundle': preKeyBundle,
      },
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

  Future<HttpClientResponse> _request(
    String method,
    String path, {
    Map<String, dynamic>? body,
  }) async {
    final client = HttpClient();

    try {
      final request = await client.openUrl(
        method,
        Uri.parse('$baseUrl$path'),
      );

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

      final response = await request.close();
      return response;
    } catch (_) {
      client.close(force: true);
      rethrow;
    }
  }

  Future<String> _readBody(HttpClientResponse response) async {
    return utf8.decoder.bind(response).join();
  }

  Map<String, dynamic> _decodeJson(String body) {
    try {
      final decoded = jsonDecode(body);

      if (decoded is! Map<String, dynamic>) {
        throw const FormatException(
          'Directory response must be a JSON object',
        );
      }

      return decoded;
    } catch (_) {
      throw const FormatException(
        'Invalid JSON returned by Directory',
      );
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
