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
        // Process Double Ratchet messages sequentially.
        _processingQueue = _processingQueue.then((_) async {
          try {
            final message =
                await _chatRepository.receiveEnvelope(rawEnvelope: bytes);

            if (message != null) {
              ref.invalidate(chatListProvider);
              ref.invalidate(chatMessagesProvider(message.chatId));
            }
          } catch (_) {
            // Invalid or undecryptable envelopes must not crash the app.
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

  ref.onDispose(listener.dispose);

  return listener;
});
