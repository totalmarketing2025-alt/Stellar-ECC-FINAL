import "dart:convert";
import "dart:typed_data";

import "package:crypto/crypto.dart";
import "package:http/http.dart" as http;

import "moderation_admin_message.dart";
import "stellar_broadcast.dart";

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


  Future<List<StellarBroadcast>> fetchBroadcasts({
    int limit = 50,
    int offset = 0,
  }) async {
    if (!isAuthenticated) {
      throw StateError(
        "Moderation admin session is not authenticated",
      );
    }

    if (limit < 1 || limit > 100 || offset < 0) {
      throw ArgumentError(
        "Invalid Broadcast pagination parameters",
      );
    }

    final uri = Uri.parse(
      "$baseUrl/v1/moderation/admin/broadcasts",
    ).replace(
      queryParameters: {
        "limit": "$limit",
        "offset": "$offset",
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
        "Broadcast list request failed (${response.statusCode})",
      );
    }

    final body =
        jsonDecode(response.body) as Map<String, dynamic>;
    final rawBroadcasts = body["broadcasts"];

    if (rawBroadcasts is! List) {
      throw StateError("Invalid Broadcast list response");
    }

    return rawBroadcasts
        .map((item) {
          if (item is! Map) {
            throw const FormatException(
              "Invalid Broadcast item",
            );
          }
          return StellarBroadcast.fromJson(
            Map<String, dynamic>.from(item),
          );
        })
        .toList();
  }

  Future<StellarBroadcast> createBroadcast({
    required String title,
    required String message,
    String? attachmentMimeType,
  }) async {
    if (!isAuthenticated) {
      throw StateError(
        "Moderation admin session is not authenticated",
      );
    }

    final cleanTitle = title.trim();

    if (cleanTitle.isEmpty || cleanTitle.length > 160) {
      throw ArgumentError("Title must contain 1–160 characters");
    }

    if (message.trim().isEmpty) {
      throw ArgumentError("Broadcast message cannot be empty");
    }

    if (utf8.encode(message).length > 256 * 1024) {
      throw ArgumentError("Broadcast message is too large");
    }

    if (attachmentMimeType != null &&
        (attachmentMimeType.trim().isEmpty ||
            attachmentMimeType.length > 128)) {
      throw ArgumentError("Invalid attachment MIME type");
    }

    final response = await http.post(
      Uri.parse("$baseUrl/v1/moderation/admin/broadcasts"),
      headers: {
        "Authorization": "Bearer $_token",
        "Content-Type": "application/json",
      },
      body: jsonEncode({
        "title": cleanTitle,
        "message": message,
        if (attachmentMimeType != null)
          "attachmentMimeType": attachmentMimeType,
      }),
    );

    if (response.statusCode == 401) {
      _token = null;
      _expiresAt = null;
      throw StateError("Moderation admin session expired");
    }

    if (response.statusCode != 201) {
      String error = "Broadcast creation failed";

      try {
        final body =
            jsonDecode(response.body) as Map<String, dynamic>;
        final value = body["error"];
        if (value is String && value.isNotEmpty) {
          error = value;
        }
      } catch (_) {}

      throw StateError("$error (${response.statusCode})");
    }

    final body =
        jsonDecode(response.body) as Map<String, dynamic>;
    final rawBroadcast = body["broadcast"];

    if (rawBroadcast is! Map) {
      throw StateError("Invalid created Broadcast response");
    }

    return StellarBroadcast.fromJson(
      Map<String, dynamic>.from(rawBroadcast),
    );
  }

  Future<void> uploadBroadcastAttachment({
    required String broadcastId,
    required String mimeType,
    required Uint8List bytes,
  }) async {
    if (!isAuthenticated) {
      throw StateError(
        "Moderation admin session is not authenticated",
      );
    }

    if (!RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
      caseSensitive: false,
    ).hasMatch(broadcastId)) {
      throw ArgumentError("Invalid Broadcast ID");
    }

    if (mimeType.trim().isEmpty || mimeType.length > 128) {
      throw ArgumentError("Invalid attachment MIME type");
    }

    if (bytes.isEmpty) {
      throw ArgumentError("Attachment cannot be empty");
    }

    if (bytes.length > 8 * 1024 * 1024) {
      throw ArgumentError(
        "Attachment is too large. Maximum size is 8 MiB.",
      );
    }

    final response = await http.post(
      Uri.parse(
        "$baseUrl/v1/moderation/admin/broadcasts/"
        "$broadcastId/attachment",
      ),
      headers: {
        "Authorization": "Bearer $_token",
        "Content-Type": mimeType,
      },
      body: bytes,
    );

    if (response.statusCode == 401) {
      _token = null;
      _expiresAt = null;
      throw StateError("Moderation admin session expired");
    }

    if (response.statusCode != 201) {
      String error = "Broadcast attachment upload failed";

      try {
        final body =
            jsonDecode(response.body) as Map<String, dynamic>;
        final value = body["error"];
        if (value is String && value.isNotEmpty) {
          error = value;
        }
      } catch (_) {}

      throw StateError("$error (${response.statusCode})");
    }
  }

  void logout() {
    _token = null;
    _expiresAt = null;
  }
}
