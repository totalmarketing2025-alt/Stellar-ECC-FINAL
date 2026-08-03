import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/storage/providers.dart';
import '../../core/security/platform_key_store.dart';
import '../../core/crypto/signal_stores.dart';
import '../../core/crypto/session_manager.dart';
import '../../core/crypto/group_crypto.dart';
import '../../core/network/relay_client.dart';
import '../../core/media/media_attachment_service.dart';
import '../../data/repositories/chat_repository.dart';
import '../../domain/models/chat.dart';
import '../../domain/models/message.dart';

const _relayUrl = 'wss://relay.stellarecc.example/v1/connect';

final platformKeyStoreProvider = Provider<PlatformKeyStore>((ref) => PlatformKeyStore());

final identityKeyStoreProvider = Provider<StellarIdentityKeyStore>((ref) {
  return StellarIdentityKeyStore(ref.watch(databaseProvider), ref.watch(platformKeyStoreProvider));
});

final sessionManagerProvider = Provider<SessionManager>((ref) {
  final db = ref.watch(databaseProvider);
  return SessionManager(
    identityStore: ref.watch(identityKeyStoreProvider),
    preKeyStore: StellarPreKeyStore(db),
    signedPreKeyStore: StellarSignedPreKeyStore(db),
    sessionStore: StellarSessionStore(db),
  );
});

final relayClientProvider = Provider<RelayClient>((ref) => RelayClient(relayUrl: _relayUrl));

final groupCryptoProvider = Provider<GroupCrypto>((ref) {
  final db = ref.watch(databaseProvider);
  return GroupCrypto(
    senderKeyStore: StellarSenderKeyStore(db),
    sessionManager: ref.watch(sessionManagerProvider),
  );
});

final mediaAttachmentServiceProvider = Provider<MediaAttachmentService>((ref) {
  return MediaAttachmentService(
    db: ref.watch(databaseProvider),
    keyStore: ref.watch(platformKeyStoreProvider),
  );
});

/// Set once the user completes onboarding / logs in; screens that need the
/// local nickname read this rather than hardcoding it.
final localNicknameProvider = StateProvider<String?>((ref) => null);

final chatRepositoryProvider = Provider<ChatRepository>((ref) {
  final nickname = ref.watch(localNicknameProvider);
  if (nickname == null) {
    throw StateError('localNicknameProvider must be set before chatRepositoryProvider is used');
  }
  return ChatRepository(
    db: ref.watch(databaseProvider),
    sessionManager: ref.watch(sessionManagerProvider),
    relayClient: ref.watch(relayClientProvider),
    localNickname: nickname,
    mediaService: ref.watch(mediaAttachmentServiceProvider),
  );
});

/// Chat list — refreshed on demand via `ref.invalidate(chatListProvider)`
/// after sends/receives/deletes, and on a periodic timer from the chat
/// list screen so expiring previews/countdowns stay live.
final chatListProvider = FutureProvider.autoDispose<List<Chat>>((ref) async {
  final repo = ref.watch(chatRepositoryProvider);
  return repo.loadChats();
});

final chatMessagesProvider =
    FutureProvider.autoDispose.family<List<Message>, String>((ref, chatId) async {
  final repo = ref.watch(chatRepositoryProvider);
  return repo.loadMessages(chatId);
});

/// App-lock state — whether the user has passed biometric/PIN auth for
/// this app session. Reset to false on cold start and on background
/// timeout (see presentation/state/app_lock_controller.dart, module 6).
final isUnlockedProvider = StateProvider<bool>((ref) => false);
