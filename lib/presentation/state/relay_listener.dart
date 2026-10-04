import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/media/attachment_payload.dart';
import '../../core/network/relay_client.dart';
import '../../core/storage/providers.dart';
import '../../core/network/envelope.dart';
import '../../data/repositories/chat_repository.dart';
import '../../domain/models/call_session.dart';
import '../../core/calls/call_signal_authenticator.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
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

  final Map<String, IdentityKey> _callIdentityCache =
      <String, IdentityKey>{};

  // Application-level replay protection for authenticated call signals.
  // A copied valid call signal can otherwise be placed into a fresh
  // relay envelope with a new delivery token.
  final Map<String, DateTime> _acceptedCallSignals =
      <String, DateTime>{};

  static const _callPrefix = 'STELLAR_CALL_V1:';
  static const _maxAcceptedCallSignals = 512;
  static const _callReplayRetention = Duration(minutes: 4);

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

          // Call signals are transport-only and intentionally bypass
          // the message Signal E2E decrypt path.
          String? plaintextCall;

          try {
            final candidate = utf8.decode(
              envelope.ciphertext,
              allowMalformed: false,
            );

            if (candidate.startsWith(_callPrefix)) {
              plaintextCall = candidate;
            }
          } catch (_) {
            // Normal message ciphertext is arbitrary binary.
          }

          if (plaintextCall != null) {
            final senderNickname = delivery.senderNickname?.trim();

            if (senderNickname == null || senderNickname.isEmpty) {
              print(
                'CALL_SIGNAL_PLAINTEXT_REJECTED: '
                'missing relay sender identity',
              );
              return;
            }

            final processed = await _routePlaintextCallSignal(
              plaintext: plaintextCall,
              senderNickname: senderNickname,
            );

            if (!processed) {
              return;
            }

            await database.messageDao.markEnvelopeProcessed(
              envelope.deliveryToken,
            );

            if (deliveryId != null) {
              await _relayClient.acknowledgeDelivery(
                deliveryId,
              );
            }

            print(
              'CALL_SIGNAL_PLAINTEXT_ROUTED: '
              'sender=${delivery.senderNickname}',
            );

            return;
          }

          // IMPORTANT:
          // This remains the single Signal decrypt path for messages.
          final decrypted = await _chatRepository.decryptEnvelope(
            rawEnvelope: bytes,
            senderNickname: delivery.senderNickname,
          );

          // Attachments are binary payloads. Detect them before attempting
          // UTF-8 decoding so arbitrary attachment bytes can never be
          // interpreted as text.
          final attachment = AttachmentPayload.decode(
            decrypted.plaintextBytes,
          );

          if (attachment != null) {
            final message = await _chatRepository.receiveDecryptedEnvelope(
              decrypted: decrypted,
            );

            if (message != null) {
              ref.invalidate(chatListProvider);
              ref.invalidate(chatMessagesProvider(message.chatId));
            }
          } else {
            // Signal-decrypted envelopes are normal chat messages.
            // Call signaling is transport-only and is handled exclusively
            // by _routePlaintextCallSignal() before Signal decryption.
            final message =
                await _chatRepository.receiveDecryptedEnvelope(
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

  Future<bool> _routePlaintextCallSignal({
    required String plaintext,
    required String senderNickname,
  }) async {
    try {
      final raw = jsonDecode(
        plaintext.substring(_callPrefix.length),
      );

      if (raw is! Map) {
        throw StateError(
          'Invalid Stellar plaintext call signal payload',
        );
      }

      final signal = <String, dynamic>{
        for (final entry in raw.entries)
          entry.key.toString(): entry.value,
      };

      final signatureValue = signal.remove('signature');

      if (signatureValue is! String ||
          signatureValue.trim().isEmpty) {
        throw StateError(
          'Missing Stellar call signal signature',
        );
      }

      final signature = base64Decode(signatureValue);

      if (signature.length != 64) {
        throw StateError(
          'Invalid Stellar call signal signature length',
        );
      }

      final sender = senderNickname.trim().toLowerCase();

      if (sender.isEmpty) {
        throw StateError(
          'Missing Stellar call signal sender',
        );
      }

      final localNickname =
          ref.read(localNicknameProvider)?.trim().toLowerCase();

      if (localNickname == null || localNickname.isEmpty) {
        throw StateError(
          'Local nickname is unavailable for call signature verification',
        );
      }

      IdentityKey? identityKey =
          _callIdentityCache[sender];

      if (identityKey == null) {
        final directoryClient =
            ref.read(directoryClientProvider);

        final remote =
            await directoryClient.lookupBundle(sender);

        identityKey = IdentityKey.fromBytes(
          base64Decode(remote.identityKey),
          0,
        );

        _callIdentityCache[sender] = identityKey;
      }

      // The directory identity key is the trust anchor.
      // Never trust senderIdentityKey from the plaintext call payload.
      var verified = CallSignalAuthenticator.verify(
        identityKey: identityKey,
        recipient: localNickname,
        payload: signal,
        signature: Uint8List.fromList(signature),
      );

      // If the cached identity failed, refresh it once. This handles
      // legitimate identity rotation without accepting an unverified
      // sender.
      if (!verified) {
        final directoryClient =
            ref.read(directoryClientProvider);

        final remote =
            await directoryClient.lookupBundle(sender);

        final refreshedIdentity =
            IdentityKey.fromBytes(
          base64Decode(remote.identityKey),
          0,
        );

        _callIdentityCache[sender] = refreshedIdentity;

        verified = CallSignalAuthenticator.verify(
          identityKey: refreshedIdentity,
          recipient: localNickname,
          payload: signal,
          signature: Uint8List.fromList(signature),
        );
      }

      if (!verified) {
        print(
          'CALL_SIGNAL_PLAINTEXT_REJECTED: '
          'invalid identity signature '
          'sender=$sender',
        );
        return false;
      }

      final type = signal['type'];
      final callId = signal['callId'];
      final kind = signal['kind'];
      final chatId = signal['chatId'];

      if (type is! String || type.isEmpty) {
        throw StateError(
          'Missing Stellar call signal type',
        );
      }

      if (callId is! String || callId.isEmpty) {
        throw StateError(
          'Missing Stellar callId',
        );
      }

      if (chatId is! String || chatId.isEmpty) {
        throw StateError(
          'Missing Stellar call chatId',
        );
      }

      if (kind != 'voice' && kind != 'video') {
        throw StateError(
          'Invalid Stellar call kind',
        );
      }

      final sentAt = signal['sentAt'];

      if (sentAt is! int) {
        throw StateError(
          'Missing Stellar call sentAt',
        );
      }

      /*
       * Replay protection happens only after:
       *   1. payload parsing
       *   2. schema validation
       *   3. identity lookup
       *   4. cryptographic signature verification
       *
       * The relay delivery token is deliberately not used because the
       * same authenticated plaintext can be copied into a new envelope.
       */
      final replayKey = <String>[
        sender,
        localNickname,
        callId,
        type,
        kind,
        chatId,
        sentAt.toString(),
        base64Encode(signature),
      ].join('|');

      final now = DateTime.now();

      _acceptedCallSignals.removeWhere(
        (_, acceptedAt) =>
            now.difference(acceptedAt) > _callReplayRetention,
      );

      if (_acceptedCallSignals.containsKey(replayKey)) {
        print(
          'CALL_SIGNAL_REPLAY_REJECTED: '
          'sender=$sender '
          'callId=$callId '
          'type=$type',
        );
        return false;
      }

      if (_acceptedCallSignals.length >= _maxAcceptedCallSignals) {
        final oldest = _acceptedCallSignals.entries.reduce(
          (a, b) => a.value.isBefore(b.value) ? a : b,
        );

        _acceptedCallSignals.remove(oldest.key);
      }

      _acceptedCallSignals[replayKey] = now;

      final session = CallSession(
        callId: callId,
        chatId: chatId,
        kind: kind == 'video'
            ? CallKind.video
            : CallKind.voice,
        state: type == 'offer'
            ? CallState.ringing
            : CallState.connecting,
        remoteNickname: sender,
      );

      ref
          .read(callSignalRouterProvider)
          .dispatch(
            session: session,
            type: type,
            payload: signal,
          );

      print(
        'CALL_SIGNAL_AUTHENTICATED: '
        'type=$type '
        'callId=$callId '
        'kind=$kind '
        'remote=$sender',
      );

      return true;
    } catch (e, stackTrace) {
      print('CALL_SIGNAL_AUTH_ERROR: $e');
      print('CALL_SIGNAL_AUTH_STACK: $stackTrace');
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
