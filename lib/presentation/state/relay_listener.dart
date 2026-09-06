import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/relay_client.dart';
import '../../data/repositories/chat_repository.dart';

class RelayListener {
  RelayListener({
    required RelayClient relayClient,
    required ChatRepository chatRepository,
  })  : _relayClient = relayClient,
        _chatRepository = chatRepository;

  final RelayClient _relayClient;
  final ChatRepository _chatRepository;

  StreamSubscription<Uint8List>? _subscription;

  void start() {
    _subscription ??= _relayClient.incoming.listen(
      (bytes) async {
        try {
          await _chatRepository.receiveEnvelope(rawEnvelope: bytes);
        } catch (_) {
          // Invalid or undecryptable envelopes must not crash the app.
        }
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
    relayClient: ref.watch(relayClientProvider),
    chatRepository: ref.watch(chatRepositoryProvider),
  );

  listener.start();

  ref.onDispose(listener.dispose);

  return listener;
});
