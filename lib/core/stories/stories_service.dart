import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'package:uuid/uuid.dart';

import '../crypto/session_manager.dart';
import '../moderation/moderation_client.dart';
import '../network/directory_client.dart';
import '../security/platform_key_store.dart';

class StellarStory {
  const StellarStory({
    required this.id,
    required this.owner,
    required this.mediaType,
    required this.durationMs,
    required this.createdAt,
    required this.expiresAt,
    required this.mediaSize,
    required this.reactionCounts,
    required this.videoExtension,
    this.wrappedKey,
  });

  final String id;
  final String owner;
  final String mediaType;
  final int durationMs;
  final int createdAt;
  final int expiresAt;
  final int mediaSize;
  final Map<String, int> reactionCounts;
  final String videoExtension;
  final String? wrappedKey;

  factory StellarStory.fromJson(Map<String, dynamic> json) {
    final counts = <String, int>{};
    final rawCounts = json['reaction_counts'];
    if (rawCounts is List) {
      for (final row in rawCounts) {
        if (row is Map && row['emoji'] is String && row['count'] is int) {
          counts[row['emoji'] as String] = row['count'] as int;
        }
      }
    }
    return StellarStory(
      id: json['story_id'] as String,
      owner: json['owner'] as String,
      mediaType: json['media_type'] as String,
      durationMs: json['duration_ms'] as int,
      createdAt: json['created_at'] as int,
      expiresAt: json['expires_at'] as int,
      mediaSize: json['media_size'] as int,
      videoExtension: (json['video_extension'] as String?) ?? 'mp4',
      reactionCounts: counts,
      wrappedKey: json['wrapped_key'] as String?,
    );
  }
}

class StoriesService {
  StoriesService({
    required this.moderationClient,
    required this.sessionManager,
    required this.directoryClient,
    required this.keyStore,
  });

  final ModerationClient moderationClient;
  final SessionManager sessionManager;
  final DirectoryClient directoryClient;
  final PlatformKeyStore keyStore;
  static const _uuid = Uuid();
  static final _aes = AesGcm.with256bits();
  static const maxStoryBytes = 25 * 1024 * 1024 - 28;
  static const maxVideoDurationMs = 15000;

  Future<void> publish({
    required String nickname,
    required List<String> audience,
    required Uint8List media,
    required String mediaType,
    required int durationMs,
    String videoExtension = 'mp4',
  }) async {
    if (media.isEmpty || media.length > maxStoryBytes) {
      throw ArgumentError('Story media must be smaller than 25 MiB.');
    }
    if (mediaType != 'image' && mediaType != 'video') {
      throw ArgumentError('Unsupported Story media type.');
    }
    if (mediaType == 'image' && durationMs != 0 ||
        mediaType == 'video' && (durationMs < 1 || durationMs > maxVideoDurationMs)) {
      throw ArgumentError('Story videos can be up to 15 seconds.');
    }
    if (mediaType == 'video' && !const {'mp4', 'mov', 'm4v', '3gp', 'webm'}.contains(videoExtension)) {
      throw ArgumentError('Unsupported Story video file format.');
    }
    final owner = nickname.trim().toLowerCase();
    final recipients = audience.map((value) => value.trim().toLowerCase())
        .where((value) => value.isNotEmpty && value != owner).toSet().toList();
    if (recipients.isEmpty || recipients.length > 100) {
      throw ArgumentError('Choose between 1 and 100 contacts.');
    }

    final storyId = _uuid.v4();
    final keyBytes = _randomBytes(32);
    final secretKey = SecretKey(keyBytes);
    final nonce = _randomBytes(12);
    final aad = _aad(
      owner: owner,
      storyId: storyId,
      mediaType: mediaType,
      durationMs: durationMs,
      videoExtension: mediaType == 'video' ? videoExtension : '',
    );
    final box = await _aes.encrypt(
      media, secretKey: secretKey, nonce: nonce, aad: aad,
    );
    final encryptedMedia = Uint8List.fromList([
      ...nonce,
      ...box.cipherText,
      ...box.mac.bytes,
    ]);

    await keyStore.writeSecret(_keyAlias(storyId), keyBytes);
    await keyStore.writeSecretText(
      _expiryAlias(storyId),
      '${DateTime.now().millisecondsSinceEpoch + 24 * 60 * 60 * 1000}',
    );
    try {
      final wrappedKeys = <Map<String, String>>[];
      for (final recipient in recipients) {
        final address = SignalProtocolAddress(recipient, 1);
        if (!await sessionManager.hasSession(address)) {
          final bundle = await directoryClient.lookupBundle(recipient);
          await sessionManager.establishSessionFromDirectory(
            remoteAddress: address,
            remoteBundle: bundle,
          );
        }
        final cipher = await sessionManager.encryptForSend(address, keyBytes);
        wrappedKeys.add({
          'nickname': recipient,
          'wrappedKey': jsonEncode({
            'type': cipher.getType(),
            'ciphertext': base64Encode(cipher.serialize()),
          }),
        });
      }
      await moderationClient.createStory(
        nickname: owner,
        encryptedMedia: encryptedMedia,
        metadata: {
          'storyId': storyId,
          'mediaType': mediaType,
          'durationMs': durationMs,
          'videoExtension': mediaType == 'video' ? videoExtension : '',
          'mediaSize': encryptedMedia.length,
          'audience': wrappedKeys,
        },
      );
    } catch (_) {
      await keyStore.deleteSecret(_keyAlias(storyId));
      await keyStore.deleteSecret(_expiryAlias(storyId));
      rethrow;
    }
  }

  Future<List<StellarStory>> load({required String nickname}) async {
    await keyStore.deleteExpiredSecrets(
      keyPrefix: 'stellar_story_key_',
      expiryPrefix: 'stellar_story_exp_',
      nowMs: DateTime.now().millisecondsSinceEpoch,
    );
    final rows = await moderationClient.fetchStories(nickname: nickname);
    return rows.map(StellarStory.fromJson).toList();
  }

  Future<Uint8List> openMedia({
    required String nickname,
    required StellarStory story,
  }) async {
    final ownerStory = story.owner.toLowerCase() == nickname.trim().toLowerCase();
    Uint8List? keyBytes = await keyStore.readSecret(_keyAlias(story.id));
    if (keyBytes == null && ownerStory) {
      throw StateError('The key for this Story is not available on this device.');
    }
    if (keyBytes == null) {
      final wrapped = story.wrappedKey;
      if (wrapped == null || wrapped.isEmpty) {
        throw StateError('This Story is not available to your account.');
      }
      final json = jsonDecode(wrapped) as Map<String, dynamic>;
      final type = json['type'];
      final bytes = base64Decode(json['ciphertext'] as String);
      final author = story.owner;
      final CiphertextMessage message;
      if (type == CiphertextMessage.prekeyType) {
        message = PreKeySignalMessage(bytes);
      } else if (type == CiphertextMessage.whisperType) {
        message = SignalMessage.fromSerialized(bytes);
      } else {
        throw const FormatException('Unsupported Story key envelope.');
      }
      keyBytes = await sessionManager.decryptReceived(
        SignalProtocolAddress(author, 1), message,
      );
      if (keyBytes.length != 32) throw const FormatException('Invalid Story key.');
      await keyStore.writeSecret(_keyAlias(story.id), keyBytes);
      await keyStore.writeSecretText(
        _expiryAlias(story.id), story.expiresAt.toString(),
      );
    }
    final encrypted = await moderationClient.fetchStoryMedia(
      nickname: nickname, storyId: story.id,
    );
    if (encrypted.length < 28 || encrypted.length > 25 * 1024 * 1024) {
      throw const FormatException('Invalid Story media.');
    }
    final nonce = encrypted.sublist(0, 12);
    final mac = Mac(encrypted.sublist(encrypted.length - 16));
    final cipherText = encrypted.sublist(12, encrypted.length - 16);
    final clear = await _aes.decrypt(
      SecretBox(cipherText, nonce: nonce, mac: mac),
      secretKey: SecretKey(keyBytes),
      aad: _aad(
        owner: story.owner,
        storyId: story.id,
        mediaType: story.mediaType,
        durationMs: story.durationMs,
        videoExtension: story.mediaType == 'video' ? story.videoExtension : '',
      ),
    );
    return Uint8List.fromList(clear);
  }

  Future<void> react({required String nickname, required StellarStory story, required String emoji}) =>
      moderationClient.reactToStory(nickname: nickname, storyId: story.id, emoji: emoji);

  Future<void> delete({required String nickname, required String storyId}) async {
    await moderationClient.deleteStory(nickname: nickname, storyId: storyId);
    await keyStore.deleteSecret(_keyAlias(storyId));
    await keyStore.deleteSecret(_expiryAlias(storyId));
  }

  String _keyAlias(String id) => 'stellar_story_key_$id';
  String _expiryAlias(String id) => 'stellar_story_exp_$id';

  List<int> _aad({
    required String owner,
    required String storyId,
    required String mediaType,
    required int durationMs,
    required String videoExtension,
  }) => utf8.encode(
    'stellar-story-v1|$owner|$storyId|$mediaType|$durationMs|$videoExtension',
  );

  Uint8List _randomBytes(int length) {
    final random = Random.secure();
    return Uint8List.fromList(List<int>.generate(length, (_) => random.nextInt(256)));
  }
}
