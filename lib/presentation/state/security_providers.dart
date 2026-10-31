import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'app_providers.dart';
import '../../core/security/platform_key_store.dart';
import '../../core/storage/providers.dart';
import '../../domain/models/device.dart';

/// Toggles that feed the security score — these mirror settings elsewhere
/// (SettingsScreen currently keeps its own local widget state; a fuller
/// build would hoist those into providers here too so there's one source
/// of truth instead of two places tracking "is biometric lock on").
final biometricLockEnabledProvider =
    StateProvider<bool>((ref) => false);
final screenshotBlockEnabledProvider = StateProvider<bool>((ref) => true);
final screenPrivacyModeEnabledProvider = StateProvider<bool>((ref) => true);
final cloudBackupEnabledProvider = StateProvider<bool>((ref) => false); // off by design, Phase 12
final wantedModeWipeEnabledProvider =
    StateNotifierProvider<WantedModeWipeEnabledNotifier, bool>(
  (ref) => WantedModeWipeEnabledNotifier(
    ref.read(platformKeyStoreProvider),
  ),
);

class WantedModeWipeEnabledNotifier extends StateNotifier<bool> {
  WantedModeWipeEnabledNotifier(this._keyStore) : super(false) {
    _load();
  }

  final PlatformKeyStore _keyStore;
  bool _operationInProgress = false;
  bool _loadInProgress = true;

  static const MethodChannel _monitorChannel =
      MethodChannel('ecc.stellar.app/wanted_mode_monitor');

  Future<bool> isChallengeStoreCorrupted() async {
    final result = await _monitorChannel.invokeMethod<bool>(
      'isChallengeStoreCorrupted',
    );

    if (result == null) {
      throw StateError('Native challenge-store status is unavailable.');
    }

    return result;
  }

  Future<List<Map<String, dynamic>>> getPendingChallenges() async {
    final result = await _monitorChannel.invokeListMethod<dynamic>(
      'getPendingChallenges',
    );

    return (result ?? const <dynamic>[])
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList(growable: false);
  }

  Future<List<Map<String, dynamic>>> getExpiredChallenges() async {
    final result = await _monitorChannel.invokeListMethod<dynamic>(
      'getExpiredChallenges',
    );

    return (result ?? const <dynamic>[])
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList(growable: false);
  }

  /// Verifies the existing app PIN before resolving exactly one challenge.
  /// Returns false for an invalid PIN, expired challenge, or native rejection.
  Future<bool> resolveChallengeAfterPin({
    required String id,
    required String pin,
  }) async {
    if (id.trim().isEmpty || pin.isEmpty) return false;

    final validPin = await _keyStore.verifyPin(pin);
    if (!validPin) return false;

    final resolved = await _monitorChannel.invokeMethod<bool>(
      'resolveChallenge',
      <String, dynamic>{'id': id},
    );

    return resolved == true;
  }

  Future<void> _load() async {
    try {
      final enabled = await _keyStore.readWantedModeWipeEnabled();

      final mirrorResult = await _monitorChannel.invokeMethod<bool>(
        'setWipeEnabled',
        <String, dynamic>{'enabled': enabled},
      );
      if (mirrorResult != true) {
        throw StateError('Native Wanted Mode preference mirror failed.');
      }

      final nativeResult = await _monitorChannel.invokeMethod<bool>(
        enabled ? 'startMonitoring' : 'stopMonitoring',
      );

      if (nativeResult != true) {
        await _disableAfterLoadFailure();
        return;
      }

      state = enabled;
    } catch (_) {
      await _disableAfterLoadFailure();
    } finally {
      _loadInProgress = false;
    }
  }

  Future<void> _disableAfterLoadFailure() async {
    state = false;

    // Do not leave a stale enabled preference after native startup failure.
    try {
      await _keyStore.writeWantedModeWipeEnabled(false);
    } catch (_) {}

    try {
      await _monitorChannel.invokeMethod<bool>(
        'setWipeEnabled',
        <String, dynamic>{'enabled': false},
      );
    } catch (_) {}

    try {
      await _monitorChannel.invokeMethod<bool>('stopMonitoring');
    } catch (_) {}
  }

  Future<void> setEnabled(bool enabled) async {
    if (_operationInProgress || _loadInProgress) {
      throw StateError(
        'Wanted Mode settings are still being initialized or updated.',
      );
    }

    _operationInProgress = true;
    var previousEnabled = false;
    var previousValueRead = false;

    try {
      previousEnabled = await _keyStore.readWantedModeWipeEnabled();
      previousValueRead = true;

      // Persist the requested preference before updating native monitoring.
      await _keyStore.writeWantedModeWipeEnabled(enabled);

      final mirrorResult = await _monitorChannel.invokeMethod<bool>(
        'setWipeEnabled',
        <String, dynamic>{'enabled': enabled},
      );
      if (mirrorResult != true) {
        throw StateError('Native Wanted Mode preference mirror failed.');
      }

      final nativeResult = await _monitorChannel.invokeMethod<bool>(
        enabled ? 'startMonitoring' : 'stopMonitoring',
      );

      if (nativeResult != true) {
        throw StateError(
          'Wanted Mode event monitoring could not be updated.',
        );
      }

      state = enabled;
    } catch (_) {
      if (!previousValueRead) {
        // We cannot safely determine the prior state.
        state = false;
        rethrow;
      }

      var preferenceRestored = false;
      try {
        await _keyStore.writeWantedModeWipeEnabled(previousEnabled);
        final mirrorRestored = await _monitorChannel.invokeMethod<bool>(
          'setWipeEnabled',
          <String, dynamic>{'enabled': previousEnabled},
        );
        if (mirrorRestored != true) {
          throw StateError('Native Wanted Mode rollback mirror failed.');
        }
        preferenceRestored = true;
      } catch (_) {
        // Do not restart native monitoring if persisted state is uncertain.
        state = false;
      }

      if (preferenceRestored) {
        try {
          final rollbackResult = await _monitorChannel.invokeMethod<bool>(
            previousEnabled ? 'startMonitoring' : 'stopMonitoring',
          );

          state = rollbackResult == true ? previousEnabled : false;
        } catch (_) {
          state = false;
        }
      }

      rethrow;
    } finally {
      _operationInProgress = false;
    }
  }
}


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
/// trigger; the UI exposes the wipe action only when the user has enabled
/// the Wanted Mode wipe option.
class WantedModeController {
  WantedModeController(this.ref);
  final Ref ref;

  void lockNow() {
    ref.read(isUnlockedProvider.notifier).state = false;
  }

  Future<void> wipeAndLock() async {
    try {
      final db = ref.read(databaseProvider);
      final keyStore = ref.read(platformKeyStoreProvider);

      await ref.read(localNicknameProvider.notifier).clear();
      await db.clearAllLocalData();

      final support = await getApplicationSupportDirectory();
      for (final name in <String>['media', 'profile_photos']) {
        final directory = Directory('${support.path}/$name');
        if (await directory.exists()) {
          await directory.delete(recursive: true);
        }
      }

      await keyStore.wipeAllExceptDatabaseKey();

      ref.invalidate(chatRepositoryProvider);
      ref.invalidate(groupCryptoProvider);
      ref.invalidate(sessionManagerProvider);
      ref.invalidate(identityKeyStoreProvider);
      ref.invalidate(profilePhotoSyncServiceProvider);
      ref.invalidate(profilePhotoServiceProvider);
      ref.invalidate(mediaAttachmentServiceProvider);
    } finally {
      lockNow();
    }
  }
}

final wantedModeControllerProvider = Provider<WantedModeController>((ref) => WantedModeController(ref));

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
