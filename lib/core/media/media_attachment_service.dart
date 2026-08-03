import 'dart:io';
import 'dart:typed_data';
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../storage/database.dart';
import '../security/platform_key_store.dart';
import 'package:cryptography/cryptography.dart' as crypto;

/// Handles attachment lifecycle: encrypt-on-write, decrypt-on-read, and
/// participates in the same TTL/secure-erase model as text messages
/// (Phase 2 §2B, ExpirySweeper._shredFile). Each media file gets its own
/// random AES-256-GCM key wrapped by the platform Keystore/Secure Enclave,
/// rather than reusing the DB's master key — limits blast radius if a
/// single wrapped key were ever compromised.
class MediaAttachmentService {
  MediaAttachmentService({required this.db, required this.keyStore});

  final StellarDatabase db;
  final PlatformKeyStore keyStore;
  final _uuid = const Uuid();
  final _aesGcm = crypto.AesGcm.with256bits();

  Future<String> storeAttachment({
    required Uint8List rawBytes,
    required String messageId,
    required String mimeType,
    required int ttlSeconds,
  }) async {
    final blobId = _uuid.v4();
    final dir = await getApplicationSupportDirectory();
    final mediaDir = Directory(p.join(dir.path, 'media'));
    if (!await mediaDir.exists()) await mediaDir.create(recursive: true);

    final filePath = p.join(mediaDir.path, '$blobId.enc');

    final secretKey = crypto.SecretKey(_randomBytes(32));
    final secretKeyBytes = await secretKey.extractBytes();
    await keyStore.writeSecret('media_key_$blobId', Uint8List.fromList(secretKeyBytes));

    final nonce = _randomBytes(12);
    final secretBox = await _aesGcm.encrypt(rawBytes, secretKey: secretKey, nonce: nonce);

    final file = File(filePath);
    await file.writeAsBytes([...nonce, ...secretBox.cipherText, ...secretBox.mac.bytes]);

    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    await db.mediaBlobDao.insert(
      blobId: blobId,
      messageId: messageId,
      mimeType: mimeType,
      filePath: filePath,
      expiresAt: now + ttlSeconds,
    );

    return blobId;
  }

  Future<Uint8List> loadAttachment(String blobId, String filePath) async {
    final keyBytes = await keyStore.readSecret('media_key_$blobId');
    if (keyBytes == null) {
      throw StateError('Media key for $blobId not found — attachment may already be expired/shredded');
    }
    final secretKey = crypto.SecretKey(keyBytes);

    final fileBytes = await File(filePath).readAsBytes();
    final nonce = fileBytes.sublist(0, 12);
    final mac = fileBytes.sublist(fileBytes.length - 16);
    final cipherText = fileBytes.sublist(12, fileBytes.length - 16);

    final secretBox = crypto.SecretBox(cipherText, nonce: nonce, mac: crypto.Mac(mac));
    final decrypted = await _aesGcm.decrypt(secretBox, secretKey: secretKey);
    return Uint8List.fromList(decrypted);
  }

  /// Called by ExpirySweeper alongside file shredding, to also remove the
  /// now-orphaned per-attachment key from secure storage.
  Future<void> wipeAttachmentKey(String blobId) => keyStore.deleteSecret('media_key_$blobId');

  Uint8List _randomBytes(int length) {
    final rand = Random.secure();
    return Uint8List.fromList(List.generate(length, (_) => rand.nextInt(256)));
  }
}
