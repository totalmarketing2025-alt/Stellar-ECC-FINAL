import 'dart:async';
import 'dart:io';

import 'database.dart';
import '../media/media_attachment_service.dart';

/// Purges expired messages and media while the app process is active, and
/// performs startup recovery for content that expired while the app was
/// suspended or terminated. Android also has a native background runner;
/// iOS does not yet register a BGTaskScheduler task, so its filesystem purge
/// is best-effort until the app next resumes or starts.
class ExpirySweeper {
  ExpirySweeper(this._db, {this.interval = const Duration(seconds: 15), MediaAttachmentService? mediaService})
      : _mediaService = mediaService;

  final StellarDatabase _db;
  final Duration interval;
  final MediaAttachmentService? _mediaService;
  Timer? _timer;

  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(interval, (_) => sweepOnce());
    // An opened View Once item is always consumed if the process stopped
    // before its viewer closed. This is a startup-only recovery step.
    unawaited(
      _db.messageDao
          .expireInterruptedViewOnce()
          .then((_) => sweepOnce())
          .catchError((Object error) {
            print('EXPIRY_SWEEPER_STARTUP_ERROR: $error');
          }),
    );
  }

  void stop() => _timer?.cancel();

  Future<void> sweepOnce() async {
    // Media must be cleaned before expired messages are deleted.
    //
    // message -> media_blob uses ON DELETE CASCADE, so deleting the
    // message first would remove the media_blob row before we get a
    // chance to shred the encrypted file and wipe its per-attachment key.
    final expiredMedia = await _db.mediaBlobDao.expired();
    for (final row in expiredMedia) {
      final path = row['file_path'] as String;
      final blobId = row['blob_id'] as String;
      await _shredFile(path);
      await _mediaService?.wipeAttachmentKey(blobId);
      await _db.mediaBlobDao.delete(blobId);
    }

    final expiredMessages = await _db.messageDao.expired();
    for (final row in expiredMessages) {
      final messageId = row['message_id'] as String;
      await _db.messageDao.secureDelete(messageId);
    }
  }

  /// Overwrite-then-delete for media files, matching the secure-erase
  /// approach used for the message text column (Phase 2 §2B / §2C).
  Future<void> _shredFile(String path) async {
    final file = File(path);
    if (!await file.exists()) return;

    final length = await file.length();
    final garbage = List<int>.generate(length, (i) => (i * 37 + 11) % 256);
    await file.writeAsBytes(garbage, flush: true);
    await file.delete();
  }
}
