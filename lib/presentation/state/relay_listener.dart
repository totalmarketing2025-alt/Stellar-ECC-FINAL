import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/relay_client.dart';
import '../../core/network/envelope.dart';
import '../../data/repositories/chat_repository.dart';
import '../../domain/models/call_session.dart';
import 'app_providers.dart';

class RelayListener {
  RelayListener({
    required this.ref,
    required RelayClient relayClient,
    required ChatRepository chatRepository,
  }) : _relayClient = relayClient,
       _chatRepository = chatRepository;

  final Ref ref;
  final RelayClient _relayClient;
  final ChatRepository _chatRepository;

  StreamSubscription<RelayDelivery>? _subscription;
  Future<void> _processingQueue = Future<void>.value();

  static const _callPrefix = 'STELLAR_CALL_V1:';

  void start() {
    _subscription ??=
        _relayClient.incomingDelivery.listen((delivery) {
      final bytes = delivery.bytes;
      final deliveryId = delivery.deliveryId;
      print('RELAY_RECEIVE: envelope received (${bytes.length} bytes)');

      _processingQueue = _processingQueue.then((_) async {
        try {
          final envelope = Envelope.decode(bytes);
          final database = ref.read(databaseProvider);

          final alreadyProcessed =
              await database.messageDao.isProcessedEnvelope(
            envelope.deliveryToken,
          );

          if (alreadyProcessed) {
            print(
              'RELAY_RECEIVE: envelope already processed; '
              'skipping Signal decrypt.',
            );

            if (deliveryId != null) {
              await _relayClient.acknowledgeDelivery(
                deliveryId,
              );
            }

            return;
          }

          // IMPORTANT:
          // This is the single Signal decrypt path.
          final decrypted = await _chatRepository.decryptEnvelope(
            rawEnvelope: bytes,
          );

          final plaintext = utf8.decode(
            decrypted.plaintextBytes,
            allowMalformed: false,
          );

          if (plaintext.startsWith(_callPrefix)) {
            final callProcessed = await _routeCallSignal(
              decrypted: decrypted,
              plaintext: plaintext,
            );

            if (!callProcessed) {
              return;
            }
          } else {
            final message = await _chatRepository.receiveDecryptedEnvelope(
              decrypted: decrypted,
            );

            if (message != null) {
              ref.invalidate(chatListProvider);
              ref.invalidate(chatMessagesProvider(message.chatId));
            }
          }

          /*
           * Persist the envelope-level dedupe marker only after
           * Signal decrypt and application processing succeeded.
           * The marker is written before Relay ACK so a later
           * duplicate delivery can be safely skipped.
           */
          await database.messageDao.markEnvelopeProcessed(
            envelope.deliveryToken,
          );

          /*
           * A queued relay envelope is removed from the server
           * only after the complete Signal decrypt + DB processing
           * path succeeds.
           */
          if (deliveryId != null) {
            await _relayClient.acknowledgeDelivery(
              deliveryId,
            );
          }

          // Keep the published directory bundle current.
          final nickname = ref.read(localNicknameProvider);

          if (nickname != null && nickname.isNotEmpty) {
            try {
              final sessionManager = ref.read(sessionManagerProvider);
              final directoryClient = ref.read(directoryClientProvider);

              await sessionManager.ensureMinimumPreKeys();

              final bundle = await sessionManager.buildLocalDirectoryBundle();

              await directoryClient.updateBundle(
                nickname: nickname,
                preKeyBundle: bundle,
              );

              print('DIRECTORY_BUNDLE_REFRESH: bundle synchronized');
            } catch (e, stackTrace) {
              print('DIRECTORY_BUNDLE_REFRESH_ERROR: $e');
              print('DIRECTORY_BUNDLE_REFRESH_STACK: $stackTrace');
            }
          }
        } catch (e, stackTrace) {
          print('RELAY_RECEIVE_ERROR: $e');
          print('RELAY_RECEIVE_STACK: $stackTrace');
        }
      });
    });
  }

  Future<bool> _routeCallSignal({
    required dynamic decrypted,
    required String plaintext,
  }) async {
    try {
      final raw = jsonDecode(plaintext.substring(_callPrefix.length));

      if (raw is! Map) {
        throw StateError('Invalid Stellar call signal payload');
      }

      final signal = <String, dynamic>{
        for (final entry in raw.entries) entry.key.toString(): entry.value,
      };

      final type = signal['type'];
      final callId = signal['callId'];
      final kind = signal['kind'];

      if (type is! String || type.isEmpty) {
        throw StateError('Missing Stellar call signal type');
      }

      if (callId is! String || callId.isEmpty) {
        throw StateError('Missing Stellar callId');
      }

      if (kind != 'voice' && kind != 'video') {
        throw StateError('Invalid Stellar call kind');
      }

      final session = CallSession(
        callId: callId,
        chatId: decrypted.chatId,
        kind: kind == 'video' ? CallKind.video : CallKind.voice,
        state: type == 'offer' ? CallState.ringing : CallState.connecting,
        remoteNickname: decrypted.senderNickname,
      );

      ref
          .read(callSignalRouterProvider)
          .dispatch(session: session, type: type, payload: signal);

      print(
        'CALL_SIGNAL_ROUTED: '
        'type=$type '
        'callId=$callId '
        'kind=$kind '
        'remote=${decrypted.senderNickname}',
      );

      return true;
    } catch (e, stackTrace) {
      print('CALL_SIGNAL_ERROR: $e');
      print('CALL_SIGNAL_STACK: $stackTrace');
      return false;
    }
  }

  Future<void> dispose() async {
    await _subscription?.cancel();
    _subscription = null;
  }
}

final relayListenerProvider = Provider<RelayListener?>((ref) {
  final nickname = ref.watch(localNicknameProvider);

  if (nickname == null || nickname.isEmpty) {
    return null;
  }

  final listener = RelayListener(
    ref: ref,
    relayClient: ref.watch(relayClientProvider),
    chatRepository: ref.watch(chatRepositoryProvider),
  );

  listener.start();

  ref.onDispose(listener.dispose);

  return listener;
});
