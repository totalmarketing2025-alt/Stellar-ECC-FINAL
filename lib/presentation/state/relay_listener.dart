import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/relay_client.dart';
import '../../data/repositories/chat_repository.dart';
import 'app_providers.dart';

class RelayListener {
  RelayListener({
    required this.ref,
    required RelayClient relayClient,
    required ChatRepository chatRepository,
  })  : _relayClient = relayClient,
        _chatRepository = chatRepository;

  final Ref ref;
  final RelayClient _relayClient;
  final ChatRepository _chatRepository;

  StreamSubscription<Uint8List>? _subscription;
  Future<void> _processingQueue = Future<void>.value();

  void start() {
    _subscription ??= _relayClient.incoming.listen(
      (bytes) {
        print('RELAY_RECEIVE: envelope received (${bytes.length} bytes)');
        // Process Double Ratchet messages sequentially.
        _processingQueue = _processingQueue.then((_) async {
          try {
            final message =
                await _chatRepository.receiveEnvelope(rawEnvelope: bytes);

            // Keep the published bundle current. PreKey refill is handled
            // by ensureMinimumPreKeys(); never infer message type from
            // serialized ciphertext bytes.
            final nickname = ref.read(localNicknameProvider);
            if (nickname != null && nickname.isNotEmpty) {
              try {
                final sessionManager = ref.read(sessionManagerProvider);
                final directoryClient = ref.read(directoryClientProvider);

                await sessionManager.ensureMinimumPreKeys();

                final bundle =
                    await sessionManager.buildLocalDirectoryBundle();

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

            if (message != null) {
              ref.invalidate(chatListProvider);
              ref.invalidate(chatMessagesProvider(message.chatId));
            }
          } catch (e, stackTrace) {
            // Never expose plaintext or ciphertext. Log only the failure
            // type/message so Signal receive failures can be diagnosed.
            print('RELAY_RECEIVE_ERROR: $e');
            print('RELAY_RECEIVE_STACK: $stackTrace');
          }
        });
      },
    );
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

  ref.onDispose(() { listener.dispose(); });

  return listener;
});
