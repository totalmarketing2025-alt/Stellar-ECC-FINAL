import "dart:convert";
import "dart:typed_data";

import "package:crypto/crypto.dart";
import "package:http/http.dart" as http;

import "moderation_admin_message.dart";

class ModerationAdminClient {
  ModerationAdminClient({
    required this.baseUrl,
  });

  final String baseUrl;

  String? _token;
  DateTime? _expiresAt;

  bool get isAuthenticated {
    final token = _token;
    final expiresAt = _expiresAt;

    return token != null &&
        token.isNotEmpty &&
        expiresAt != null &&
        expiresAt.isAfter(DateTime.now());
  }

  Future<void> authenticate(String adminSecret) async {
    final secret = adminSecret.trim();

    if (secret.isEmpty) {
      throw ArgumentError("Admin secret cannot be empty");
    }

    final challengeResponse = await http.post(
      Uri.parse("$baseUrl/v1/moderation/admin/challenge"),
      headers: const {
        "Content-Type": "application/json",
      },
    );

    if (challengeResponse.statusCode != 200) {
      throw StateError(
        "Admin challenge failed (${challengeResponse.statusCode})",
      );
    }

    final challengeBody =
        jsonDecode(challengeResponse.body) as Map<String, dynamic>;

    final challenge = challengeBody["challenge"] as String?;

    if (challenge == null || challenge.isEmpty) {
      throw StateError("Invalid admin challenge response");
    }

    final secretBytes = Uint8List.fromList(utf8.encode(secret));
    final challengeBytes = Uint8List.fromList(utf8.encode(challenge));

    final mac = Hmac(sha256, secretBytes);
    final digest = mac.convert(challengeBytes);

    final proof = base64UrlEncode(digest.bytes);

    final verifyResponse = await http.post(
      Uri.parse("$baseUrl/v1/moderation/admin/verify"),
      headers: const {
        "Content-Type": "application/json",
      },
      body: jsonEncode({
        "challenge": challenge,
        "proof": proof,
      }),
    );

    if (verifyResponse.statusCode != 200) {
      String message = "Admin authentication failed";

      try {
        final body =
            jsonDecode(verifyResponse.body) as Map<String, dynamic>;
        final error = body["error"];
        if (error is String && error.isNotEmpty) {
          message = error;
        }
      } catch (_) {}

      throw StateError(
        "$message (${verifyResponse.statusCode})",
      );
    }

    final body =
        jsonDecode(verifyResponse.body) as Map<String, dynamic>;

    final token = body["token"] as String?;
    final expiresAtMs = (body["expiresAt"] as num?)?.toInt();

    if (token == null || token.isEmpty || expiresAtMs == null) {
      throw StateError("Invalid admin session response");
    }

    _token = token;
    _expiresAt = DateTime.fromMillisecondsSinceEpoch(expiresAtMs);
  }

  Future<List<ModerationAdminMessage>> fetchMessages({
    int limit = 50,
    int offset = 0,
  }) async {
    if (!isAuthenticated) {
      throw StateError("Moderation admin session is not authenticated");
    }

    final safeLimit = limit.clamp(1, 100);
    final safeOffset = offset < 0 ? 0 : offset;

    final uri = Uri.parse(
      "$baseUrl/v1/moderation/admin/messages",
    ).replace(
      queryParameters: {
        "limit": "$safeLimit",
        "offset": "$safeOffset",
      },
    );

    final response = await http.get(
      uri,
      headers: {
        "Authorization": "Bearer $_token",
      },
    );

    if (response.statusCode == 401) {
      _token = null;
      _expiresAt = null;
      throw StateError("Moderation admin session expired");
    }

    if (response.statusCode != 200) {
      throw StateError(
        "Moderation messages request failed (${response.statusCode})",
      );
    }

    final body =
        jsonDecode(response.body) as Map<String, dynamic>;

    final rawMessages = body["messages"];

    if (rawMessages is! List) {
      throw StateError("Invalid moderation messages response");
    }

    return rawMessages
        .whereType<Map>()
        .map(
          (item) => ModerationAdminMessage.fromJson(
            Map<String, dynamic>.from(item),
          ),
        )
        .toList();
  }

  Future<Uint8List> fetchAttachment(String messageId) async {
    if (!isAuthenticated) {
      throw StateError(
        "Moderation admin session is not authenticated",
      );
    }

    if (messageId.isEmpty || messageId.length > 256) {
      throw ArgumentError("Invalid moderation message ID");
    }

    final uri = Uri.parse(
      "$baseUrl/v1/moderation/admin/messages/"
      "${Uri.encodeComponent(messageId)}/attachment",
    );

    final response = await http.get(
      uri,
      headers: {
        "Authorization": "Bearer $_token",
      },
    );

    if (response.statusCode == 401) {
      _token = null;
      _expiresAt = null;
      throw StateError("Moderation admin session expired");
    }

    if (response.statusCode != 200) {
      String message =
          "Attachment request failed (${response.statusCode})";

      try {
        final body =
            jsonDecode(response.body) as Map<String, dynamic>;
        final error = body["error"];

        if (error is String && error.isNotEmpty) {
          message = "$error (${response.statusCode})";
        }
      } catch (_) {}

      throw StateError(message);
    }

    return response.bodyBytes;
  }

  void logout() {
    _token = null;
    _expiresAt = null;
  }
}
