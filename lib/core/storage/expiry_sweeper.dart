import 'dart:async';
import 'dart:io';

import 'database.dart';
import '../media/media_attachment_service.dart';

/// Enforces the "messages disappear after their TTL" guarantee while the
/// app is running (a foreground ticker), and is additionally invoked from
/// a platform-scheduled background task (WorkManager on Android /
/// BGTaskScheduler on iOS — wired up in the native platform channels,
/// see android/app and ios/Runner background task registration) since
/// neither OS guarantees a Dart isolate timer fires while backgrounded.
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
    // Run once immediately on startup too, in case the app was closed for
    // longer than `interval` and messages are already stale on launch.
    sweepOnce();
  }

  void stop() => _timer?.cancel();

  Future<void> sweepOnce() async {
    final expiredMessages = await _db.messageDao.expired();
    for (final row in expiredMessages) {
      final messageId = row['message_id'] as String;
      await _db.messageDao.secureDelete(messageId);
    }

    final expiredMedia = await _db.mediaBlobDao.expired();
    for (final row in expiredMedia) {
      final path = row['file_path'] as String;
      final blobId = row['blob_id'] as String;
      await _shredFile(path);
      await _mediaService?.wipeAttachmentKey(blobId);
      await _db.mediaBlobDao.delete(blobId);
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
