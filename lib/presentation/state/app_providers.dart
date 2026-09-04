import 'dart:typed_data';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/storage/providers.dart';
import '../../core/security/platform_key_store.dart';
import '../../core/crypto/signal_stores.dart';
import '../../core/crypto/session_manager.dart';
import '../../core/crypto/group_crypto.dart';
import '../../core/network/relay_client.dart';
import '../../core/network/directory_client.dart';
import '../../core/media/media_attachment_service.dart';
import '../../data/repositories/chat_repository.dart';
import '../../domain/models/chat.dart';
import '../../domain/models/message.dart';

const _relayUrl = 'wss://relay.stellarecc.example/v1/connect';
const _directoryUrl = 'https://directory.stellarecc.example';

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

final directoryClientProvider = Provider<DirectoryClient>((ref) {
  return DirectoryClient(
    baseUrl: _directoryUrl,
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

/// Persistent local Stellar nickname.
///
/// The nickname is stored in PlatformKeyStore so it survives app restarts.
/// The in-memory Riverpod state is kept in sync through [load] and [setNickname].
class LocalNicknameController extends StateNotifier<String?> {
  LocalNicknameController(this._keyStore) : super(null);

  final PlatformKeyStore _keyStore;

  static const _storageKey = 'stellar.local_nickname';

  Future<void> load() async {
    final value = await _keyStore.readSecret(_storageKey);
    state = value == null ? null : String.fromCharCodes(value);
  }

  Future<void> setNickname(String nickname) async {
    final value = nickname.trim();
    if (value.isEmpty) {
      throw ArgumentError('Nickname cannot be empty');
    }

    await _keyStore.writeSecret(
      _storageKey,
      Uint8List.fromList(value.codeUnits),
    );

    state = value;
  }

  Future<void> clear() async {
    await _keyStore.deleteSecret(_storageKey);
    state = null;
  }
}

final localNicknameProvider =
    StateNotifierProvider<LocalNicknameController, String?>((ref) {
  return LocalNicknameController(ref.watch(platformKeyStoreProvider));
});

final chatRepositoryProvider = Provider<ChatRepository>((ref) {
  final nickname = ref.watch(localNicknameProvider);
  if (nickname == null) {
    throw StateError('localNicknameProvider must be set before chatRepositoryProvider is used');
  }
  return ChatRepository(
    db: ref.watch(databaseProvider),
    sessionManager: ref.watch(sessionManagerProvider),
    relayClient: ref.watch(relayClientProvider),
    directoryClient: ref.watch(directoryClientProvider),
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
