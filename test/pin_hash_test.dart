import 'package:flutter_test/flutter_test.dart';
import 'package:stellar_ecc/core/security/pin_hash.dart';

void main() {
  test('PBKDF2-HMAC-SHA256 matches known one-iteration test vector', () async {
    final result = await derivePinVerifier(
      'password',
      'salt'.codeUnits,
      iterations: 1,
    );
    expect(
      result.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join(),
      '120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b',
    );
  });
}
