import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

import '../crypto/signal_stores.dart';
import '../network/directory_client.dart';
import 'profile_photo_service.dart';

/// Synchronizes public profile photos with the Stellar directory.
///
/// Local copies are stored through ProfilePhotoService, which encrypts
/// photos at rest. Server uploads are authenticated with the user's
/// Signal identity key.
class ProfilePhotoSyncService {
  ProfilePhotoSyncService({
    required DirectoryClient directoryClient,
    required StellarIdentityKeyStore identityKeyStore,
    required ProfilePhotoService localPhotoService,
  })  : _directoryClient = directoryClient,
        _identityKeyStore = identityKeyStore,
        _localPhotoService = localPhotoService;

  static const int _deviceId = 1;
  static const int _maxUploadBytes = 512 * 1024;

  static const Set<String> _supportedMimeTypes = {
    'image/jpeg',
    'image/png',
    'image/webp',
  };

  final DirectoryClient _directoryClient;
  final StellarIdentityKeyStore _identityKeyStore;
  final ProfilePhotoService _localPhotoService;

  /// Uploads a profile photo after signing the exact directory auth message.
  ///
  /// The local encrypted copy should be saved by the caller as part of
  /// the existing profile-photo workflow.
  Future<void> uploadPhoto({
    required String nickname,
    required Uint8List imageBytes,
  }) async {
    final normalizedNickname = _normalizeNickname(nickname);
    if (normalizedNickname.isEmpty) {
      throw ArgumentError.value(nickname, 'nickname', 'Must not be empty.');
    }

    if (imageBytes.isEmpty || imageBytes.length > _maxUploadBytes) {
      throw ArgumentError(
        'Profile photos must be between 1 byte and 512 KiB to upload.',
      );
    }

    final mimeType = _detectMimeType(imageBytes);
    if (!_supportedMimeTypes.contains(mimeType)) {
      throw ArgumentError(
        'Unsupported profile photo format. Use JPEG, PNG, or WebP.',
      );
    }

    final identityKeyPair =
        await _identityKeyStore.getIdentityKeyPair();
    final registrationId =
        await _identityKeyStore.getLocalRegistrationId();

    final challenge = await _directoryClient.getProfilePhotoChallenge(
      nickname: normalizedNickname,
      deviceId: _deviceId,
      registrationId: registrationId,
      operation: 'put',
    );

    final photoHash = sha256.convert(imageBytes).toString();

    final message = DirectoryClient.buildProfilePhotoAuthMessage(
      nickname: normalizedNickname,
      deviceId: _deviceId,
      registrationId: registrationId,
      operation: 'put',
      mimeType: mimeType,
      sha256Hex: photoHash,
      challenge: challenge,
    );

    final signature = Curve.calculateSignature(
      identityKeyPair.getPrivateKey(),
      Uint8List.fromList(utf8.encode(message)),
    );

    await _directoryClient.uploadProfilePhoto(
      nickname: normalizedNickname,
      deviceId: _deviceId,
      registrationId: registrationId,
      challenge: challenge,
      signature: base64Encode(signature),
      mimeType: mimeType,
      photoBase64: base64Encode(imageBytes),
    );
  }

  /// Fetches a remote photo and stores it in the encrypted local photo store.
  ///
  /// Returns null when the directory has no photo for this nickname.
  Future<Uint8List?> fetchAndCachePhoto(String nickname) async {
    final normalizedNickname = _normalizeNickname(nickname);
    if (normalizedNickname.isEmpty) {
      throw ArgumentError.value(nickname, 'nickname', 'Must not be empty.');
    }

    final result =
        await _directoryClient.fetchProfilePhoto(normalizedNickname);

    if (result == null) {
      return null;
    }

    final mimeType = result['mimeType'];
    final encodedPhoto = result['photo'];

    if (mimeType is! String ||
        !_supportedMimeTypes.contains(mimeType) ||
        encodedPhoto is! String) {
      throw const FormatException('Invalid profile photo response.');
    }

    final Uint8List bytes;
    try {
      bytes = base64Decode(encodedPhoto);
    } on FormatException {
      throw const FormatException(
        'The directory returned invalid profile photo data.',
      );
    }

    if (bytes.isEmpty || !_matchesMimeType(bytes, mimeType)) {
      throw const FormatException(
        'The profile photo data does not match its MIME type.',
      );
    }

    await _localPhotoService.savePhoto(
      userId: normalizedNickname,
      imageBytes: bytes,
    );

    return bytes;
  }

  /// Requests a one-use delete challenge and signs the delete operation.
  Future<void> deletePhoto(String nickname) async {
    final normalizedNickname = _normalizeNickname(nickname);
    if (normalizedNickname.isEmpty) {
      throw ArgumentError.value(nickname, 'nickname', 'Must not be empty.');
    }

    final identityKeyPair =
        await _identityKeyStore.getIdentityKeyPair();
    final registrationId =
        await _identityKeyStore.getLocalRegistrationId();

    final challenge = await _directoryClient.getProfilePhotoChallenge(
      nickname: normalizedNickname,
      deviceId: _deviceId,
      registrationId: registrationId,
      operation: 'delete',
    );

    final message = DirectoryClient.buildProfilePhotoAuthMessage(
      nickname: normalizedNickname,
      deviceId: _deviceId,
      registrationId: registrationId,
      operation: 'delete',
      mimeType: '',
      sha256Hex: '',
      challenge: challenge,
    );

    final signature = Curve.calculateSignature(
      identityKeyPair.getPrivateKey(),
      Uint8List.fromList(utf8.encode(message)),
    );

    await _directoryClient.deleteProfilePhoto(
      nickname: normalizedNickname,
      deviceId: _deviceId,
      registrationId: registrationId,
      challenge: challenge,
      signature: base64Encode(signature),
    );

    await _localPhotoService.removePhoto(normalizedNickname);
  }

  static String _normalizeNickname(String nickname) =>
      nickname.trim().toLowerCase();

  static String _detectMimeType(Uint8List bytes) {
    if (bytes.length >= 3 &&
        bytes[0] == 0xFF &&
        bytes[1] == 0xD8 &&
        bytes[2] == 0xFF) {
      return 'image/jpeg';
    }

    if (bytes.length >= 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47 &&
        bytes[4] == 0x0D &&
        bytes[5] == 0x0A &&
        bytes[6] == 0x1A &&
        bytes[7] == 0x0A) {
      return 'image/png';
    }

    if (bytes.length >= 12 &&
        bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      return 'image/webp';
    }

    return 'application/octet-stream';
  }

  static bool _matchesMimeType(Uint8List bytes, String mimeType) {
    return _detectMimeType(bytes) == mimeType;
  }
}
