import 'dart:convert';
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
