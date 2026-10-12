import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart' as crypto;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../security/platform_key_store.dart';

/// Local-only encrypted profile photo storage.
///
/// The photo is encrypted with its own random AES-256-GCM key.
/// The key and active photo identifier are stored in PlatformKeyStore.
/// Encrypted files remain inside the app's private support directory.
class ProfilePhotoService {
  ProfilePhotoService({required this.keyStore});

  final PlatformKeyStore keyStore;

  // Serialize photo operations per profile to avoid pointer/key races.
  final Map<String, Future<void>> _ownerLocks = {};

  Future<T> _withOwnerLock<T>(
    String userId,
    Future<T> Function() operation,
  ) async {
    final key = _ownerId(userId);
    final previous = _ownerLocks[key] ?? Future<void>.value();
    final gate = Completer<void>();
    _ownerLocks[key] = gate.future;

    try {
      await previous;
      return await operation();
    } finally {
      if (!gate.isCompleted) gate.complete();
      if (identical(_ownerLocks[key], gate.future)) {
        _ownerLocks.remove(key);
      }
    }
  }

  static const _activePrefix = 'stellar.profile_photo.active.';
  static const _keyPrefix = 'stellar.profile_photo.key.';
  static const _directoryName = 'profile_photos';

  final _aesGcm = crypto.AesGcm.with256bits();
  final _uuid = const Uuid();

  final Random _random = Random.secure();

  String _ownerId(String userId) {
    return sha256.convert(utf8.encode(userId.trim())).toString();
  }

  String _activeAlias(String userId) =>
      '$_activePrefix${_ownerId(userId)}';

  String _keyAlias(String photoId) => '$_keyPrefix$photoId';

  Future<Directory> _photoDirectory() async {
    final support = await getApplicationSupportDirectory();
    final directory = Directory(p.join(support.path, _directoryName));

    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }

    return directory;
  }

  Future<File?> _fileFor(String photoId) async {
    // UUIDs are generated internally, but validate stored identifiers too.
    if (!RegExp(
      r'^[0-9a-fA-F-]{36}$',
    ).hasMatch(photoId)) {
      return null;
    }

    final directory = await _photoDirectory();
    return File(p.join(directory.path, '$photoId.enc'));
  }

  Uint8List _randomBytes(int length) {
    return Uint8List.fromList(
      List<int>.generate(length, (_) => _random.nextInt(256)),
    );
  }

  /// Encrypt and store a replacement before switching the active photo.
  Future<void> savePhoto({
    required String userId,
    required Uint8List imageBytes,
  }) {
    return _withOwnerLock<void>(
      userId,
      () => _savePhoto(userId: userId, imageBytes: imageBytes),
    );
  }

  Future<void> _savePhoto({
    required String userId,
    required Uint8List imageBytes,
  }) async {
    final owner = userId.trim();

    if (owner.isEmpty) {
      throw ArgumentError('A profile identity is required.');
    }

    if (imageBytes.isEmpty) {
      throw ArgumentError('The selected image is empty.');
    }

    // Keep the profile image bounded to avoid excessive memory/storage use.
    if (imageBytes.length > 10 * 1024 * 1024) {
      throw ArgumentError('The image must be 10 MB or smaller.');
    }

    final previousId =
        await keyStore.readSecret(_activeAlias(owner));

    final photoId = _uuid.v4();
    final keyBytes = _randomBytes(32);
    final nonce = _randomBytes(12);
    final secretKey = crypto.SecretKey(keyBytes);

    File? newFile;
    var keyWritten = false;
    var activePointerWritten = false;

    try {
      final box = await _aesGcm.encrypt(
        imageBytes,
        secretKey: secretKey,
        nonce: nonce,
        aad: utf8.encode('stellar-profile-photo-v1:$owner'),
      );

      newFile = await _fileFor(photoId);
      if (newFile == null) {
        throw StateError('Unable to create profile photo.');
      }

      await newFile.writeAsBytes(
        [
          ...nonce,
          ...box.cipherText,
          ...box.mac.bytes,
        ],
        flush: true,
      );

      // Mark rollback ownership before awaiting storage: a write may
      // persist successfully and still throw before returning.
      keyWritten = true;
      await keyStore.writeSecret(
        _keyAlias(photoId),
        Uint8List.fromList(keyBytes),
      );

      activePointerWritten = true;
      await keyStore.writeSecret(
        _activeAlias(owner),
        Uint8List.fromList(utf8.encode(photoId)),
      );
    } catch (_) {
      // If the active-pointer write may have changed storage, restore the
      // previous pointer before removing the new key or encrypted file.
      // If restoration fails, preserve the new material: the active pointer
      // may still reference it.
      var safeToCleanupNewPhoto = !activePointerWritten;

      if (activePointerWritten) {
        try {
          if (previousId != null) {
            await keyStore.writeSecret(
              _activeAlias(owner),
              previousId,
            );
          } else {
            await keyStore.deleteSecret(_activeAlias(owner));
          }
          safeToCleanupNewPhoto = true;
        } catch (_) {
          // Keep the new key/file if pointer restoration cannot be confirmed.
        }
      }

      if (safeToCleanupNewPhoto && keyWritten) {
        try {
          await keyStore.deleteSecret(_keyAlias(photoId));
        } catch (_) {}
      }

      if (safeToCleanupNewPhoto && newFile != null) {
        try {
          if (await newFile.exists()) {
            await newFile.delete();
          }
        } catch (_) {}
      }

      rethrow;
    }

    // The new photo is active. Cleanup of an old photo must not
    // turn a successful save into a reported failure.
    if (previousId != null) {
      try {
        final oldId = utf8.decode(previousId, allowMalformed: false);

        if (oldId != photoId &&
            RegExp(r'^[0-9a-fA-F-]{36}$').hasMatch(oldId)) {
          try {
            await keyStore.deleteSecret(_keyAlias(oldId));
          } catch (_) {}

          try {
            final oldFile = await _fileFor(oldId);
            if (oldFile != null && await oldFile.exists()) {
              await oldFile.delete();
            }
          } catch (_) {}
        }
      } catch (_) {
        // Ignore corrupt previous metadata; the new photo is already active.
      }
    }
  }

  /// Returns decrypted image bytes, or null when no local photo exists.
  Future<Uint8List?> loadPhoto(String userId) {
    return _withOwnerLock<Uint8List?>(
      userId,
      () => _loadPhoto(userId),
    );
  }

  Future<Uint8List?> _loadPhoto(String userId) async {
    final owner = userId.trim();
    if (owner.isEmpty) return null;

    try {
      final activeBytes =
          await keyStore.readSecret(_activeAlias(owner));

      if (activeBytes == null) return null;

      final photoId = utf8.decode(activeBytes, allowMalformed: false);

      if (!RegExp(r'^[0-9a-fA-F-]{36}$').hasMatch(photoId)) {
        return null;
      }

      final keyBytes = await keyStore.readSecret(_keyAlias(photoId));
      if (keyBytes == null || keyBytes.length != 32) {
        return null;
      }

      final file = await _fileFor(photoId);
      if (file == null || !await file.exists()) {
        return null;
      }

      final encrypted = await file.readAsBytes();

      // 12-byte nonce + at least a 16-byte GCM authentication tag.
      if (encrypted.length < 28) return null;

      final nonce = encrypted.sublist(0, 12);
      final cipherText = encrypted.sublist(12, encrypted.length - 16);
      final mac = encrypted.sublist(encrypted.length - 16);

      final box = crypto.SecretBox(
        cipherText,
        nonce: nonce,
        mac: crypto.Mac(mac),
      );

      final plaintext = await _aesGcm.decrypt(
        box,
        secretKey: crypto.SecretKey(keyBytes),
        aad: utf8.encode('stellar-profile-photo-v1:$owner'),
      );

      return Uint8List.fromList(plaintext);
    } catch (_) {
      // Never expose cryptographic or filesystem internals to the UI.
      return null;
    }
  }

  /// Removes the active photo and its corresponding encryption key.
  Future<void> removePhoto(String userId) {
    return _withOwnerLock<void>(
      userId,
      () => _removePhoto(userId),
    );
  }

  Future<void> _removePhoto(String userId) async {
    final owner = userId.trim();
    if (owner.isEmpty) return;

    final alias = _activeAlias(owner);
    final activeBytes = await keyStore.readSecret(alias);

    if (activeBytes == null) return;

    // Validate metadata before changing the active pointer.
    final String photoId;
    try {
      photoId = utf8.decode(activeBytes, allowMalformed: false);
    } on FormatException {
      throw StateError('Profile photo metadata is invalid.');
    }

    if (!RegExp(r'^[0-9a-fA-F-]{36}$').hasMatch(photoId)) {
      throw StateError('Profile photo identifier is invalid.');
    }

    // Remove the pointer first. If this fails, leave the key and file intact.
    await keyStore.deleteSecret(alias);

    // The photo is no longer active. Cleanup is best-effort so a filesystem
    // failure does not falsely imply that the active photo is still present.
    try {
      await keyStore.deleteSecret(_keyAlias(photoId));
    } catch (_) {}

    try {
      final file = await _fileFor(photoId);
      if (file != null && await file.exists()) {
        await file.delete();
      }
    } catch (_) {}
  }

}
