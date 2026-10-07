import 'dart:async';
import 'dart:typed_data';

import '../media/media_attachment_service.dart';
import '../storage/database.dart';
import 'moderation_client.dart';
import 'moderation_message.dart';

class ModerationOutboxService {
  ModerationOutboxService({
    required this.db,
    required this.client,
    required this.mediaService,
    required this.nickname,
  });

  final StellarDatabase db;
  final ModerationClient client;
  final MediaAttachmentService? mediaService;
  final String nickname;

  Timer? _timer;
  bool _running = false;
  bool _disposed = false;

  Future<void> start() async {
    if (_disposed) return;

    _timer ??= Timer.periodic(
      const Duration(seconds: 30),
      (_) => unawaited(flush()),
    );

    await flush();
  }

  void scheduleFlush() {
    if (_disposed) return;
    unawaited(flush());
  }

  Future<void> flush() async {
    if (_disposed || _running) return;

    _running = true;
    try {
      while (!_disposed) {
        final rows = await db.moderationOutboxDao.due(limit: 10);
        if (rows.isEmpty) break;

        for (final row in rows) {
          if (_disposed) break;
          await _process(row);
        }
      }
    } finally {
      _running = false;
    }
  }

  Future<void> _process(Map<String, Object?> row) async {
    final messageId = row['message_id'] as String;

    try {
      final messageRow = await db.messageDao.byId(messageId);

      if (messageRow == null) {
        await db.moderationOutboxDao.delete(messageId);
        return;
      }

      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final expiresAt = messageRow['expires_at'] as int;

      if (expiresAt <= now) {
        await db.moderationOutboxDao.delete(messageId);
        return;
      }

      final direction = row['direction'] as String;
      final sender = row['sender'] as String;
      final recipient = row['recipient'] as String;
      final chatId = row['chat_id'] as String?;
      final contentType = row['content_type'] as String;
      final plaintext = row['plaintext'] as String;
      final attachmentMimeType =
          row['attachment_mime_type'] as String?;
      final attachmentBlobId =
          row['attachment_blob_id'] as String?;

      Uint8List? attachmentBytes;

      if (attachmentBlobId != null) {
        final service = mediaService;
        if (service == null) {
          throw StateError('MediaAttachmentService unavailable');
        }

        final blob = await db.mediaBlobDao.byId(attachmentBlobId);
        if (blob == null) {
          await db.moderationOutboxDao.delete(messageId);
          return;
        }

        final blobExpiresAt = blob['expires_at'] as int;
        if (blobExpiresAt <= now) {
          await db.moderationOutboxDao.delete(messageId);
          return;
        }

        final filePath = blob['file_path'] as String;
        attachmentBytes = await service.loadAttachment(
          attachmentBlobId,
          filePath,
        );
      }

      final moderationMessage = ModerationMessage(
        messageId: messageId,
        sender: sender,
        recipient: recipient,
        chatId: chatId,
        createdAt: row['created_at'] as int,
        contentType: contentType,
        plaintext: plaintext,
        attachmentMimeType: attachmentMimeType,
        attachmentBytes: attachmentBytes,
      );

      if (direction == 'outgoing') {
        await client.sendMessage(
          moderationMessage,
          nickname: nickname,
        );
      } else if (direction == 'incoming') {
        await client.sendReceivedMessage(
          moderationMessage,
          nickname: nickname,
        );
      } else {
        throw StateError('Unknown moderation outbox direction');
      }

      if (attachmentBytes != null && attachmentMimeType != null) {
        if (direction == 'outgoing') {
          await client.sendAttachment(
            messageId: messageId,
            mimeType: attachmentMimeType,
            bytes: attachmentBytes,
            nickname: nickname,
          );
        } else {
          await client.sendReceivedAttachment(
            messageId: messageId,
            mimeType: attachmentMimeType,
            bytes: attachmentBytes,
            nickname: nickname,
          );
        }
      }

      await db.moderationOutboxDao.delete(messageId);

      print(
        'MODERATION_OUTBOX_SUCCESS: '
        'messageId=$messageId direction=$direction',
      );
    } catch (error, stackTrace) {
      final attempt = (row['attempt_count'] as int) + 1;

      final delaySeconds = _retryDelaySeconds(attempt);
      final nextAttemptAt =
          DateTime.now().millisecondsSinceEpoch ~/ 1000 +
              delaySeconds;

      await db.moderationOutboxDao.retry(
        messageId: messageId,
        attemptCount: attempt,
        nextAttemptAt: nextAttemptAt,
        lastError: error.toString(),
      );

      print(
        'MODERATION_OUTBOX_RETRY: '
        'messageId=$messageId '
        'attempt=$attempt '
        'next=${delaySeconds}s '
        'error=$error',
      );
      print('MODERATION_OUTBOX_RETRY_STACK: $stackTrace');
    }
  }

  int _retryDelaySeconds(int attempt) {
    const maxDelay = 3600;
    var delay = 30;

    for (var i = 1; i < attempt; i++) {
      if (delay >= maxDelay ~/ 2) {
        delay = maxDelay;
        break;
      }
      delay *= 2;
    }

    return delay > maxDelay ? maxDelay : delay;
  }

  Future<void> dispose() async {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
  }
}
