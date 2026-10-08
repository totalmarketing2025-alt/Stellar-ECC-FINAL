import 'dart:async';
import 'dart:typed_data';

import '../storage/database.dart';
import 'relay_client.dart';

/// Durable recovery worker for outgoing encrypted relay envelopes.
///
/// The outbox contains only opaque, already-encrypted envelope bytes.
/// Plaintext message content is intentionally never stored here.
class OutgoingTransportOutboxService {
  OutgoingTransportOutboxService({
    required this.db,
    required this.relayClient,
    required this.onRelaySent,
  });

  final StellarDatabase db;
  final RelayClient relayClient;

  /// Called after an envelope has definitely been handed to the relay
  /// and the durable outbox has transitioned to relay_sent.
  final Future<void> Function(String messageId) onRelaySent;

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
        final rows = await db.transportOutboxDao.due(limit: 10);

        if (rows.isEmpty) {
          break;
        }

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
    final envelopeBytes = row['envelope_bytes'] as Uint8List;
    final state = row['state'] as String;

    try {
      if (state == 'pending') {
        await relayClient.send(envelopeBytes);

        await db.transportOutboxDao.markRelaySent(messageId);

        print(
          'TRANSPORT_OUTBOX_RELAY_SENT: '
          'messageId=$messageId',
        );

        await onRelaySent(messageId);
      } else if (state == 'relay_sent') {
        // The relay send already succeeded before a possible crash.
        // Recover the post-send lifecycle through ChatRepository.
        print(
          'TRANSPORT_OUTBOX_RELAY_ALREADY_SENT: '
          'messageId=$messageId',
        );

        await onRelaySent(messageId);
      } else {
        throw StateError(
          'Unknown transport outbox state: $state',
        );
      }
    } catch (error, stackTrace) {
      final attempt = (row['attempt_count'] as int) + 1;
      final delaySeconds = _retryDelaySeconds(attempt);
      final nextAttemptAt =
          DateTime.now().millisecondsSinceEpoch ~/ 1000 +
              delaySeconds;

      await db.transportOutboxDao.retry(
        messageId: messageId,
        attemptCount: attempt,
        nextAttemptAt: nextAttemptAt,
        lastError: error.toString(),
      );

      print(
        'TRANSPORT_OUTBOX_RETRY: '
        'messageId=$messageId '
        'attempt=$attempt '
        'next=${delaySeconds}s '
        'error=$error',
      );

      print(
        'TRANSPORT_OUTBOX_RETRY_STACK: '
        '$stackTrace',
      );
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
