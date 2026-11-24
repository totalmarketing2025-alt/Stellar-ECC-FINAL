import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

const accountRecoveryFormat = 'stellar-account-recovery-v1';
const accountRecoveryKeyAlias = 'stellar.account_recovery_key';
const _recoveryKdfIterations = 600000;
const _backupAad = 'stellar-account-recovery-v1';

class RecoveredAccountIdentity {
  const RecoveredAccountIdentity({
    required this.nickname,
    required this.identityKeyPair,
    required this.registrationId,
    required this.recoveryKey,
  });

  final String nickname;
  final Uint8List identityKeyPair;
  final int registrationId;
  final Uint8List recoveryKey;
}

class CreatedAccountRecoveryBackup {
  const CreatedAccountRecoveryBackup({
    required this.fileBytes,
    required this.recoveryKey,
  });

  final Uint8List fileBytes;
  final Uint8List recoveryKey;
}

class AccountRecoveryService {
  static final _aes = AesGcm.with256bits();

  static Future<String> wrapStoryKey({
    required String owner,
    required String storyId,
    required Uint8List storyKey,
    required Uint8List recoveryKey,
  }) async {
    if (storyKey.length != 32 || recoveryKey.length != 32) {
      throw ArgumentError('Story recovery keys must be 256 bits.');
    }
    final normalizedOwner = _validateNickname(owner);
    final nonce = _randomBytes(12);
    final box = await _aes.encrypt(
      storyKey,
      secretKey: SecretKey(recoveryKey),
      nonce: nonce,
      aad: _storyAad(normalizedOwner, storyId),
    );
    return jsonEncode({
      'version': 1,
      'nonce': base64Encode(nonce),
      'ciphertext': base64Encode(box.cipherText),
      'mac': base64Encode(box.mac.bytes),
    });
  }

  static Future<Uint8List> unwrapStoryKey({
    required String owner,
    required String storyId,
    required String envelope,
    required Uint8List recoveryKey,
  }) async {
    if (recoveryKey.length != 32 || envelope.length > 4096) {
      throw const FormatException('Invalid Story recovery envelope.');
    }
    try {
      final value = jsonDecode(envelope);
      if (value is! Map<String, dynamic> || value['version'] != 1) {
        throw const FormatException('Unsupported Story recovery envelope.');
      }
      final nonce = _decodeBase64(value['nonce'], expectedLength: 12);
      final ciphertext = _decodeBase64(value['ciphertext'], expectedLength: 32);
      final mac = _decodeBase64(value['mac'], expectedLength: 16);
      final key = await _aes.decrypt(
        SecretBox(ciphertext, nonce: nonce, mac: Mac(mac)),
        secretKey: SecretKey(recoveryKey),
        aad: _storyAad(_validateNickname(owner), storyId),
      );
      if (key.length != 32) throw const FormatException('Invalid Story key.');
      return Uint8List.fromList(key);
    } on SecretBoxAuthenticationError {
      throw const FormatException('Recovery key does not match this Story.');
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('Invalid Story recovery envelope.');
    }
  }

  /// Creates a portable encrypted identity file. The passphrase-derived key
  /// also wraps the owner's Story keys; the passphrase is never put in the file.
  static Future<CreatedAccountRecoveryBackup> createBackup({
    required String nickname,
    required Uint8List identityKeyPair,
    required int registrationId,
    required String passphrase,
  }) async {
    final owner = _validateNickname(nickname);
    _validatePassphrase(passphrase);
    if (identityKeyPair.isEmpty || identityKeyPair.length > 512 ||
        registrationId < 1 || registrationId > 0x7fffffff) {
      throw ArgumentError('Invalid identity recovery data.');
    }
    final salt = _randomBytes(16);
    final recoveryKey = await _deriveKey(passphrase, salt);
    final nonce = _randomBytes(12);
    final clear = utf8.encode(jsonEncode({
      'nickname': owner,
      'identityKeyPair': base64Encode(identityKeyPair),
      'registrationId': registrationId,
    }));
    final box = await _aes.encrypt(
      clear,
      secretKey: SecretKey(recoveryKey),
      nonce: nonce,
      aad: utf8.encode(_backupAad),
    );
    final fileBytes = Uint8List.fromList(utf8.encode(jsonEncode({
      'format': accountRecoveryFormat,
      'kdf': 'pbkdf2-hmac-sha256',
      'iterations': _recoveryKdfIterations,
      'salt': base64Encode(salt),
      'nonce': base64Encode(nonce),
      'ciphertext': base64Encode(box.cipherText),
      'mac': base64Encode(box.mac.bytes),
    })));
    return CreatedAccountRecoveryBackup(
      fileBytes: fileBytes,
      recoveryKey: recoveryKey,
    );
  }

  static Future<RecoveredAccountIdentity> openBackup({
    required Uint8List backup,
    required String passphrase,
  }) async {
    _validatePassphrase(passphrase);
    if (backup.isEmpty || backup.length > 64 * 1024) {
      throw const FormatException('Invalid recovery file size.');
    }
    try {
      final document = jsonDecode(utf8.decode(backup));
      if (document is! Map<String, dynamic> ||
          document['format'] != accountRecoveryFormat ||
          document['kdf'] != 'pbkdf2-hmac-sha256' ||
          document['iterations'] != _recoveryKdfIterations) {
        throw const FormatException('Unsupported recovery file.');
      }
      final salt = _decodeBase64(document['salt'], expectedLength: 16);
      final nonce = _decodeBase64(document['nonce'], expectedLength: 12);
      final ciphertext = _decodeBase64(document['ciphertext']);
      final mac = _decodeBase64(document['mac'], expectedLength: 16);
      if (ciphertext.isEmpty || ciphertext.length > 4096) {
        throw const FormatException('Invalid recovery payload.');
      }
      final recoveryKey = await _deriveKey(passphrase, salt);
      final clear = await _aes.decrypt(
        SecretBox(ciphertext, nonce: nonce, mac: Mac(mac)),
        secretKey: SecretKey(recoveryKey),
        aad: utf8.encode(_backupAad),
      );
      final payload = jsonDecode(utf8.decode(clear));
      if (payload is! Map<String, dynamic>) {
        throw const FormatException('Invalid recovery payload.');
      }
      final nickname = _validateNickname(payload['nickname']);
      final identityBytes = _decodeBase64(payload['identityKeyPair']);
      final registrationId = payload['registrationId'];
      if (identityBytes.isEmpty || identityBytes.length > 512 ||
          registrationId is! int || registrationId < 1 ||
          registrationId > 0x7fffffff) {
        throw const FormatException('Invalid recovered identity.');
      }
      return RecoveredAccountIdentity(
        nickname: nickname,
        identityKeyPair: identityBytes,
        registrationId: registrationId,
        recoveryKey: recoveryKey,
      );
    } on SecretBoxAuthenticationError {
      throw const FormatException('Recovery passphrase is incorrect or the file is damaged.');
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('Recovery passphrase is incorrect or the file is damaged.');
    }
  }

  static Future<Uint8List> _deriveKey(String passphrase, List<int> salt) async {
    final key = await Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: _recoveryKdfIterations,
      bits: 256,
    ).deriveKey(secretKey: SecretKey(utf8.encode(passphrase)), nonce: salt);
    return Uint8List.fromList(await key.extractBytes());
  }

  static List<int> _storyAad(String owner, String storyId) =>
      utf8.encode('stellar-story-recovery-v1|$owner|$storyId');

  static void _validatePassphrase(String value) {
    if (value.trim().length < 16 || value.length > 256) {
      throw ArgumentError('Use a recovery passphrase between 16 and 256 characters.');
    }
  }

  static String _validateNickname(Object? value) {
    if (value is! String) throw const FormatException('Invalid recovered nickname.');
    final nickname = value.trim().toLowerCase();
    if (!RegExp(r'^[a-z0-9_.-]{1,64}$').hasMatch(nickname)) {
      throw const FormatException('Invalid recovered nickname.');
    }
    return nickname;
  }

  static Uint8List _decodeBase64(Object? value, {int? expectedLength}) {
    if (value is! String || value.isEmpty ||
        !RegExp(r'^[A-Za-z0-9+/]+={0,2}$').hasMatch(value)) {
      throw const FormatException('Invalid recovery file encoding.');
    }
    final bytes = Uint8List.fromList(base64Decode(value));
    if (expectedLength != null && bytes.length != expectedLength) {
      throw const FormatException('Invalid recovery file encoding.');
    }
    return bytes;
  }

  static Uint8List _randomBytes(int length) {
    final random = Random.secure();
    return Uint8List.fromList(List<int>.generate(length, (_) => random.nextInt(256)));
  }
}
