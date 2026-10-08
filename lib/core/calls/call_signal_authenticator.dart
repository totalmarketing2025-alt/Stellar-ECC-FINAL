import 'dart:convert';
import 'dart:typed_data';

import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

class CallSignalAuthenticator {
  static const protocol = 'stellar-call-auth-v2';
  static const maxAge = Duration(minutes: 3);

  static Uint8List sign({
    required IdentityKeyPair identityKeyPair,
    required String recipient,
    required Map<String, dynamic> payload,
  }) {
    final message = _canonicalMessage(
      recipient: recipient,
      payload: payload,
    );

    return Curve.calculateSignature(
      identityKeyPair.getPrivateKey(),
      Uint8List.fromList(utf8.encode(message)),
    );
  }

  static bool verify({
    required IdentityKey identityKey,
    required String recipient,
    required Map<String, dynamic> payload,
    required Uint8List signature,
    DateTime? now,
  }) {
    final sentAt = payload['sentAt'];

    if (sentAt is! int) {
      return false;
    }

    final payloadRecipient = payload['recipient'];

    if (payloadRecipient is! String ||
        payloadRecipient.trim().toLowerCase() !=
            recipient.trim().toLowerCase()) {
      return false;
    }

    final issued = DateTime.fromMillisecondsSinceEpoch(sentAt);
    final current = now ?? DateTime.now();

    if (current.difference(issued).abs() > maxAge) {
      return false;
    }

    final message = _canonicalMessage(
      recipient: recipient,
      payload: payload,
    );

    try {
      return Curve.verifySignature(
        Curve.decodePoint(identityKey.serialize(), 0),
        Uint8List.fromList(utf8.encode(message)),
        signature,
      );
    } catch (_) {
      return false;
    }
  }

  static String _canonicalMessage({
    required String recipient,
    required Map<String, dynamic> payload,
  }) {
    return jsonEncode(<dynamic>[
      protocol,
      recipient,
      _canonicalize(payload),
    ]);
  }

  static dynamic _canonicalize(dynamic value) {
    if (value is Map) {
      final entries = value.entries
          .map(
            (entry) => MapEntry(
              entry.key.toString(),
              _canonicalize(entry.value),
            ),
          )
          .toList()
        ..sort((a, b) => a.key.compareTo(b.key));

      return <String, dynamic>{
        for (final entry in entries)
          entry.key: entry.value,
      };
    }

    if (value is List) {
      return value.map(_canonicalize).toList();
    }

    return value;
  }
}
