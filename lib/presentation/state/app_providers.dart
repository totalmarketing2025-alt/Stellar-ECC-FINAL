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
import '../../core/profile/profile_photo_service.dart';
import '../../core/profile/profile_photo_sync_service.dart';
import '../../core/moderation/moderation_client.dart';
import '../../core/moderation/moderation_admin_client.dart';
import '../../core/calls/call_signal_router.dart';
import '../../core/calls/call_coordinator.dart';
import '../../core/calls/call_platform_bridge.dart';
import '../../core/calls/call_service.dart';
import '../../data/repositories/chat_repository.dart';
import '../../domain/models/chat.dart';
import '../../domain/models/message.dart';
import '../../domain/models/call_event.dart';

const _relayUrl =
    'wss://stellar-ecc-final.totalmarketing2025.workers.dev/v1/connect';
const _directoryUrl =
    'https://stellar-ecc-directory.totalmarketing2025.workers.dev';
const _moderationUrl =
    'https://stellar-ecc-final.totalmarketing2025.workers.dev';

final platformKeyStoreProvider = Provider<PlatformKeyStore>(
  (ref) => PlatformKeyStore(),
);

final identityKeyStoreProvider = Provider<StellarIdentityKeyStore>((ref) {
  return StellarIdentityKeyStore(
    ref.watch(databaseProvider),
    ref.watch(platformKeyStoreProvider),
  );
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

final moderationAdminClientProvider =
    Provider<ModerationAdminClient>((ref) {
  final client = ModerationAdminClient(
    baseUrl: _moderationUrl,
  );

  ref.onDispose(client.logout);

  return client;
});

final moderationClientProvider = Provider<ModerationClient>((ref) {
  final client = ModerationClient(
    baseUrl: _moderationUrl,
    identityStore: ref.watch(identityKeyStoreProvider),
  );

  ref.onDispose(client.dispose);

  return client;
});

final directoryClientProvider = Provider<DirectoryClient>((ref) {
  final client = DirectoryClient(baseUrl: _directoryUrl);

  ref.onDispose(client.dispose);

  return client;
});

final relayClientProvider = Provider<RelayClient>(
  (ref) => RelayClient(
    relayUrl: _relayUrl,
    identityStore: ref.watch(identityKeyStoreProvider),
  ),
);

final callSignalRouterProvider = Provider<CallSignalRouter>((ref) {
  final router = CallSignalRouter();
  ref.onDispose(router.dispose);
  return router;
});

final callPlatformBridgeProvider = Provider<CallPlatformBridge>((ref) {
  final bridge = CallPlatformBridge();
  ref.onDispose(bridge.dispose);
  return bridge;
});

final callServiceProvider = Provider<CallService>((ref) {
  final nickname = ref.watch(localNicknameProvider);
  if (nickname == null || nickname.isEmpty) {
    throw StateError('localNicknameProvider must be set before callServiceProvider is used');
  }

  final service = CallService(
    relayClient: ref.watch(relayClientProvider),
    sessionManager: ref.watch(sessionManagerProvider),
    platformBridge: ref.watch(callPlatformBridgeProvider),
    directoryClient: ref.watch(directoryClientProvider),
    localNickname: nickname,
  );
  ref.onDispose(service.end);
  return service;
});

final callCoordinatorProvider = Provider<CallCoordinator>((ref) {
  final coordinator = CallCoordinator(
    signalRouter: ref.watch(callSignalRouterProvider),
    callService: ref.watch(callServiceProvider),
    platformBridge: ref.watch(callPlatformBridgeProvider),
    onCallHistoryEvent: (event) async {
      final repo = ref.read(chatRepositoryProvider);
      final chatRow = await repo.db.chatDao.byId(event.chatId);
      if (chatRow == null || chatRow['chat_type'] != 'direct') return;

      final ttlValue = chatRow['default_ttl_sec'];
      final ttl = ttlValue is int && ttlValue > 0 ? ttlValue : 3600;
      await repo.sendDirectMessage(
        chatId: event.chatId,
        plaintext: event.encode(),
        ttlSeconds: ttl,
      );
      ref.invalidate(chatMessagesProvider(event.chatId));
      ref.invalidate(chatListProvider);
    },
  );

  coordinator.start();
  ref.onDispose(coordinator.dispose);

  return coordinator;
});

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

/// Locally encrypted profile-photo storage.
final profilePhotoServiceProvider = Provider<ProfilePhotoService>((ref) {
  return ProfilePhotoService(
    keyStore: ref.watch(platformKeyStoreProvider),
  );
});


/// Synchronizes profile photos with the directory and encrypted local cache.
final profilePhotoSyncServiceProvider =
    Provider<ProfilePhotoSyncService>((ref) {
  return ProfilePhotoSyncService(
    directoryClient: ref.watch(directoryClientProvider),
    identityKeyStore: ref.watch(identityKeyStoreProvider),
    localPhotoService: ref.watch(profilePhotoServiceProvider),
  );
});

/// Refreshes a profile photo from the directory while retaining the
/// encrypted local copy as a fallback when the network is unavailable.
final profilePhotoBytesProvider =
    FutureProvider.autoDispose.family<Uint8List?, String>(
  (ref, nickname) async {
    final localService = ref.watch(profilePhotoServiceProvider);
    final syncService = ref.watch(profilePhotoSyncServiceProvider);
    final localNickname = ref.watch(localNicknameProvider);

    final normalizedNickname = nickname.trim().toLowerCase();
    final isOwnProfile = localNickname != null &&
        normalizedNickname == localNickname.trim().toLowerCase();

    Uint8List? cached = await localService.loadPhoto(normalizedNickname);
    Uint8List? legacyCached;

    // Older versions stored the trimmed nickname with its original casing.
    // Try that owner key before concluding that no local photo exists.
    final originalNickname = nickname.trim();
    if (cached == null &&
        originalNickname.isNotEmpty &&
        originalNickname != normalizedNickname) {
      legacyCached = await localService.loadPhoto(originalNickname);

      if (legacyCached != null) {
        try {
          // Save using the canonical owner/AAD before removing the legacy key.
          await localService.savePhoto(
            userId: normalizedNickname,
            imageBytes: legacyCached,
          );
          cached = legacyCached;

          try {
            await localService.removePhoto(originalNickname);
          } catch (_) {
            // The canonical copy is safe; a leftover legacy copy is harmless.
          }
        } catch (_) {
          // Keep the readable legacy bytes available as a fallback.
        }
      }
    }

    try {
      final remote =
          await syncService.fetchAndCachePhoto(normalizedNickname);

      if (remote != null) return remote;

      // Preserve a local photo on the owner's profile if no remote copy exists.
      if (isOwnProfile) return cached ?? legacyCached;

      // A missing or invalid remote record must not erase a readable
      // local copy. Keep the cache and let a later refresh retry.
      return cached ?? legacyCached;
    } catch (_) {
      // A network/server error is not proof that the photo was deleted.
      return cached ?? legacyCached;
    }
  },
);

/// Persistent local Stellar nickname.
///
/// The nickname is stored in PlatformKeyStore so it survives app restarts.
/// The in-memory Riverpod state is kept in sync through [load] and [setNickname].
class LocalNicknameController extends StateNotifier<String?> {
  LocalNicknameController(this._keyStore, this._relayClient) : super(null);

  final PlatformKeyStore _keyStore;
  final RelayClient _relayClient;

  static const _storageKey = 'stellar.local_nickname';

  Future<void> load() async {
    final value = await _keyStore.readSecret(_storageKey);
    state = value == null ? null : String.fromCharCodes(value);
    if (state != null && state!.isNotEmpty) {
      await _relayClient.connect(peer: state!);
    }
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
    await _relayClient.connect(peer: value);
  }

  Future<void> clear() async {
    await _keyStore.deleteSecret(_storageKey);
    state = null;
    await _relayClient.disconnect();
  }
}

final localNicknameProvider =
    StateNotifierProvider<LocalNicknameController, String?>((ref) {
      return LocalNicknameController(
        ref.watch(platformKeyStoreProvider),
        ref.watch(relayClientProvider),
      );
    });

final chatRepositoryProvider = Provider<ChatRepository>((ref) {
  final nickname = ref.watch(localNicknameProvider);
  if (nickname == null) {
    throw StateError(
      'localNicknameProvider must be set before chatRepositoryProvider is used',
    );
  }
  final repository = ChatRepository(
    db: ref.watch(databaseProvider),
    sessionManager: ref.watch(sessionManagerProvider),
    relayClient: ref.watch(relayClientProvider),
    directoryClient: ref.watch(directoryClientProvider),
    localNickname: nickname,
    mediaService: ref.watch(mediaAttachmentServiceProvider),
    moderationClient: ref.watch(moderationClientProvider),
  );

  ref.onDispose(repository.dispose);

  return repository;
});

/// Chat list — refreshed on demand via `ref.invalidate(chatListProvider)`
/// after sends/receives/deletes, and on a periodic timer from the chat
/// list screen so expiring previews/countdowns stay live.
final chatListProvider = FutureProvider.autoDispose<List<Chat>>((ref) async {
  final repo = ref.watch(chatRepositoryProvider);
  return repo.loadChats();
});

final chatMessagesProvider = FutureProvider.autoDispose
    .family<List<Message>, String>((ref, chatId) async {
      final repo = ref.watch(chatRepositoryProvider);
      return repo.loadMessages(chatId);
    });

/// App-lock state — whether the user has passed biometric/PIN auth for
/// this app session. Reset to false on cold start and on background
/// timeout (see presentation/state/app_lock_controller.dart, module 6).
final isUnlockedProvider = StateProvider<bool>((ref) => false);
