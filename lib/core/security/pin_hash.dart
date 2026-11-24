import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

const pinKdfIterations = 600000;

/// Derives a 256-bit verifier for an app PIN using PBKDF2-HMAC-SHA256.
Future<Uint8List> derivePinVerifier(
  String pin,
  List<int> salt, {
  int iterations = pinKdfIterations,
}) async {
  if (iterations < 1) {
    throw ArgumentError.value(iterations, 'iterations', 'Must be positive');
  }
  final algorithm = Pbkdf2(
    macAlgorithm: Hmac.sha256(),
    iterations: iterations,
    bits: 256,
  );
  final key = await algorithm.deriveKey(
    secretKey: SecretKey(utf8.encode(pin)),
    nonce: salt,
  );
  return Uint8List.fromList(await key.extractBytes());
}
