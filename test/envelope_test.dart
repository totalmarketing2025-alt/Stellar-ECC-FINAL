import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:stellar_ecc/core/network/envelope.dart';

void main() {
  group('Envelope', () {
    test('round-trips all fields', () {
      final original = Envelope(
        envelopeVersion: 1,
        relayTtlSeconds: 300,
        deliveryToken: Uint8List.fromList([1, 2, 3, 4]),
        recipientRoute: 'bob_test',
        ciphertext: Uint8List.fromList([10, 20, 30, 40, 50]),
      );

      final decoded = Envelope.decode(original.encode());

      expect(decoded.envelopeVersion, 1);
      expect(decoded.relayTtlSeconds, 300);
      expect(decoded.deliveryToken, [1, 2, 3, 4]);
      expect(decoded.recipientRoute, 'bob_test');
      expect(decoded.ciphertext, [10, 20, 30, 40, 50]);
    });

    test('round-trips UTF-8 recipient route', () {
      final original = Envelope(
        recipientRoute: 'тест_用户',
        deliveryToken: Uint8List.fromList([1]),
        ciphertext: Uint8List.fromList([2, 3]),
      );

      final decoded = Envelope.decode(original.encode());

      expect(decoded.recipientRoute, 'тест_用户');
    });

    test('rejects truncated envelope', () {
      expect(
        () => Envelope.decode(Uint8List.fromList([0x00, 0x01])),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects corrupted token length', () {
      final valid = Envelope(
        recipientRoute: 'bob',
        deliveryToken: Uint8List.fromList([1, 2]),
        ciphertext: Uint8List.fromList([3, 4]),
      ).encode();

      final corrupted = Uint8List.fromList(valid);
      corrupted[6] = 0xFF;
      corrupted[7] = 0xFF;

      expect(
        () => Envelope.decode(corrupted),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects corrupted ciphertext length', () {
      final valid = Envelope(
        recipientRoute: 'bob',
        deliveryToken: Uint8List.fromList([1, 2]),
        ciphertext: Uint8List.fromList([3, 4]),
      ).encode();

      final corrupted = Uint8List.fromList(valid);

      // Last four bytes of the header contain ciphertext length.
      final ciphertextLengthOffset =
          2 + 4 + 2 + 2 + 3 + 4;
      corrupted[ciphertextLengthOffset] = 0xFF;
      corrupted[ciphertextLengthOffset + 1] = 0xFF;
      corrupted[ciphertextLengthOffset + 2] = 0xFF;
      corrupted[ciphertextLengthOffset + 3] = 0xFF;

      expect(
        () => Envelope.decode(corrupted),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects trailing bytes', () {
      final valid = Envelope(
        recipientRoute: 'bob',
        deliveryToken: Uint8List.fromList([1]),
        ciphertext: Uint8List.fromList([2]),
      ).encode();

      final corrupted = Uint8List.fromList([
        ...valid,
        0xAA,
      ]);

      expect(
        () => Envelope.decode(corrupted),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
