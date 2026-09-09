import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Wraps flutter_secure_storage, which on Android is backed by the
/// AndroidKeystore-encrypted EncryptedSharedPreferences and on iOS by the
/// Keychain (optionally Secure-Enclave-gated via the accessibility flag
/// below). Only small, high-value secrets go here (identity key material,
/// the database encryption key) — never bulk message content.
class PlatformKeyStore {
  PlatformKeyStore()
      : _storage = const FlutterSecureStorage(
          aOptions: AndroidOptions(
            encryptedSharedPreferences: true,
          ),
          iOptions: IOSOptions(
            accessibility: KeychainAccessibility.first_unlock_this_device,
            synchronizable: false, // never sync identity keys via iCloud Keychain
          ),
        );

  final FlutterSecureStorage _storage;
  final Random _secureRandom = Random.secure();

  static const _dbKeyAlias = 'stellar_ecc.db_master_key';

  static const _pinHashAlias = 'stellar_ecc.app_pin_hash';
  static const _pinSaltAlias = 'stellar_ecc.app_pin_salt';
  static const _pinFailedAttemptsAlias = 'stellar_ecc.pin_failed_attempts';

  Future<bool> hasPin() async {
    return await _storage.read(key: _pinHashAlias) != null;
  }

  Future<void> setPin(String pin) async {
    final salt = _generateRandomKey(16);
    final hash = sha256.convert(
      [...salt, ...utf8.encode(pin)],
    ).bytes;

    await _storage.write(
      key: _pinSaltAlias,
      value: base64Encode(salt),
    );
    await _storage.write(
      key: _pinHashAlias,
      value: base64Encode(hash),
    );
  }

  Future<int> getPinFailedAttempts() async {
    final raw = await _storage.read(key: _pinFailedAttemptsAlias);
    return int.tryParse(raw ?? '0') ?? 0;
  }

  Future<int> incrementPinFailedAttempts() async {
    final attempts = await getPinFailedAttempts() + 1;
    await _storage.write(
      key: _pinFailedAttemptsAlias,
      value: attempts.toString(),
    );
    return attempts;
  }

  Future<void> resetPinFailedAttempts() async {
    await _storage.delete(key: _pinFailedAttemptsAlias);
  }

  Future<bool> verifyPin(String pin) async {
    final saltRaw = await _storage.read(key: _pinSaltAlias);
    final hashRaw = await _storage.read(key: _pinHashAlias);

    if (saltRaw == null || hashRaw == null) return false;

    final salt = base64Decode(saltRaw);
    final expected = base64Decode(hashRaw);
    final actual = sha256.convert(
      [...salt, ...utf8.encode(pin)],
    ).bytes;

    if (actual.length != expected.length) return false;

    var difference = 0;
    for (var i = 0; i < actual.length; i++) {
      difference |= actual[i] ^ expected[i];
    }

    return difference == 0;
  }


  Future<Uint8List> getOrCreateDatabaseKey() async {
    final existing = await _storage.read(key: _dbKeyAlias);
    if (existing != null) {
      return base64Decode(existing);
    }
    final key = _generateRandomKey(32); // 256-bit key for SQLCipher
    await _storage.write(key: _dbKeyAlias, value: base64Encode(key));
    return key;
  }

  Future<void> writeSecret(String key, Uint8List value) =>
      _storage.write(key: key, value: base64Encode(value));

  Future<Uint8List?> readSecret(String key) async {
    final raw = await _storage.read(key: key);
    return raw == null ? null : base64Decode(raw);
  }

  Future<void> deleteSecret(String key) => _storage.delete(key: key);

  /// Full wipe — used by the "Reset Identity" flow and account deletion.
  Future<void> wipeAll() => _storage.deleteAll();

  Uint8List _generateRandomKey(int length) {
    final bytes = Uint8List(length);
    for (var i = 0; i < length; i++) {
      bytes[i] = _secureRandom.nextInt(256);
    }
    return bytes;
  }
}
