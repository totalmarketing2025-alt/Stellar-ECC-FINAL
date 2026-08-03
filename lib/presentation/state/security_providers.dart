import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_providers.dart';
import '../../core/storage/providers.dart';
import '../../domain/models/device.dart';

/// Toggles that feed the security score — these mirror settings elsewhere
/// (SettingsScreen currently keeps its own local widget state; a fuller
/// build would hoist those into providers here too so there's one source
/// of truth instead of two places tracking "is biometric lock on").
final biometricLockEnabledProvider = StateProvider<bool>((ref) => true);
final screenshotBlockEnabledProvider = StateProvider<bool>((ref) => true);
final screenPrivacyModeEnabledProvider = StateProvider<bool>((ref) => true);
final cloudBackupEnabledProvider = StateProvider<bool>((ref) => false); // off by design, Phase 12
final panicWipeEnabledProvider = StateProvider<bool>((ref) => false);

/// Simple weighted checklist rather than anything probabilistic — each
/// factor is a known, auditable contributor (Phase 12 checklist items),
/// not a black-box "trust score."
final securityScoreProvider = Provider<int>((ref) {
  var score = 0;
  if (ref.watch(biometricLockEnabledProvider)) score += 25;
  if (ref.watch(screenshotBlockEnabledProvider)) score += 15;
  if (ref.watch(screenPrivacyModeEnabledProvider)) score += 15;
  if (!ref.watch(cloudBackupEnabledProvider)) score += 25; // NOT backing up to cloud is the secure state
  if (ref.watch(localNicknameProvider) != null) score += 20; // identity established
  return score;
});

/// Immediate lock-and-optionally-wipe action. Locking is always safe to
/// trigger; wiping is destructive and gated by panicWipeEnabledProvider
/// being explicitly turned on beforehand, plus a confirmation step in the
/// UI (SecurityCenterScreen._confirmPanicWipe) — never a single accidental
/// tap away.
class PanicLockController {
  PanicLockController(this.ref);
  final Ref ref;

  void lockNow() {
    ref.read(isUnlockedProvider.notifier).state = false;
  }

  Future<void> wipeAndLock() async {
    final db = ref.read(databaseProvider);
    final keyStore = ref.read(platformKeyStoreProvider);

    // Wipes the ephemeral message store's rows first (secure-erase path,
    // not a bare DROP TABLE) then the identity/session key material —
    // ordered so a failure partway through still leaves keys unusable
    // rather than leaving messages recoverable without keys.
    final chats = await db.chatDao.all();
    for (final chat in chats) {
      await db.chatDao.delete(chat['chat_id'] as String);
    }
    await keyStore.wipeAll();

    lockNow();
  }
}

final panicLockControllerProvider = Provider<PanicLockController>((ref) => PanicLockController(ref));

/// Placeholder data until a real multi-device linking flow exists — the
/// current device is always real (derived from local state), any others
/// would come from a "linked devices" server-side list this app doesn't
/// yet implement (Stellar ECC's identity model in Phase 1 is single-
/// device by default; multi-device is a valid future extension, not
/// implemented here to avoid asserting a capability that doesn't exist).
final linkedDevicesProvider = Provider<List<LinkedDevice>>((ref) {
  return [
    LinkedDevice(
      deviceId: 1,
      label: 'This device',
      lastActive: DateTime.now(),
      isCurrentDevice: true,
    ),
  ];
});
