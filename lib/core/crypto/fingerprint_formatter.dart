import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as std_crypto;
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

/// Derives a human-comparable fingerprint from an identity public key,
/// used both as the standalone "encryption key fingerprint" shown in the
/// Security Center and as an input to the per-contact safety number
/// (Phase 3 §7). Uses SHA-256 over the serialized public key, formatted
/// as grouped hex — not a new cryptographic primitive, just a display
/// transform over an already-authenticated key.
class FingerprintFormatter {
  static String forIdentityKey(IdentityKey identityKey) {
    final hash = std_crypto.sha256.convert(identityKey.serialize());
    return _formatGrouped(Uint8List.fromList(hash.bytes));
  }

  /// Combines both parties' identity keys (sorted so both sides compute
  /// the same value regardless of who's "local") into a single safety
  /// number for a 1:1 chat — the value users compare out-of-band.
  static String forSafetyNumber(IdentityKey localKey, IdentityKey remoteKey) {
    final a = localKey.serialize();
    final b = remoteKey.serialize();
    final ordered = _compareBytes(a, b) <= 0 ? [...a, ...b] : [...b, ...a];
    final hash = std_crypto.sha256.convert(ordered);
    return _formatGrouped(Uint8List.fromList(hash.bytes));
  }

  static String _formatGrouped(Uint8List bytes) {
    // 12 groups of 5 digits, in the same visual style as Signal's safety
    // numbers — derived from the hash bytes taken 5 at a time modulo
    // 100000, purely a legibility transform for manual comparison.
    final groups = <String>[];
    for (var i = 0; i < 12 && i * 2 < bytes.length; i++) {
      final chunk = (bytes[(i * 2) % bytes.length] << 8) | bytes[(i * 2 + 1) % bytes.length];
      groups.add((chunk % 100000).toString().padLeft(5, '0'));
    }
    return groups.join(' ');
  }

  static int _compareBytes(List<int> a, List<int> b) {
    final len = a.length < b.length ? a.length : b.length;
    for (var i = 0; i < len; i++) {
      if (a[i] != b[i]) return a[i] - b[i];
    }
    return a.length - b.length;
  }
}
