import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:local_auth/local_auth.dart';

import 'app_providers.dart';
import 'security_providers.dart';

class AppLockController {
  AppLockController(this.ref);

  final Ref ref;
  final LocalAuthentication _localAuth = LocalAuthentication();

  static const _storageKey = 'stellar.biometric_lock_enabled';

  Future<bool> isBiometricLockEnabled() async {
    final value =
        await ref.read(platformKeyStoreProvider).readSecret(_storageKey);

    return value != null && value.isNotEmpty && value.first == 1;
  }

  Future<void> loadEnabledState() async {
    final enabled = await isBiometricLockEnabled();
    ref.read(biometricLockEnabledProvider.notifier).state = enabled;
  }

  Future<bool> enableBiometricLock() async {
    try {
      final supported = await _localAuth.isDeviceSupported();

      if (!supported) {
        return false;
      }

      final authenticated = await _localAuth.authenticate(
        localizedReason: 'Confirm biometric lock for Stellar ECC',
        options: const AuthenticationOptions(
          biometricOnly: true,
          stickyAuth: true,
        ),
      );

      if (!authenticated) {
        return false;
      }

      await ref.read(platformKeyStoreProvider).writeSecret(
        _storageKey,
        Uint8List.fromList([1]),
      );

      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> disableBiometricLock() async {
    await ref.read(platformKeyStoreProvider).deleteSecret(_storageKey);
  }

  Future<bool> authenticate() async {
    try {
      final enabled = await isBiometricLockEnabled();

      if (!enabled) {
        ref.read(isUnlockedProvider.notifier).state = true;
        return true;
      }

      final authenticated = await _localAuth.authenticate(
        localizedReason: 'Unlock Stellar ECC',
        options: const AuthenticationOptions(
          biometricOnly: true,
          stickyAuth: true,
        ),
      );

      ref.read(isUnlockedProvider.notifier).state = authenticated;

      return authenticated;
    } catch (_) {
      ref.read(isUnlockedProvider.notifier).state = false;
      return false;
    }
  }

  void lock() {
    ref.read(isUnlockedProvider.notifier).state = false;
  }
}

final appLockControllerProvider = Provider<AppLockController>(
  (ref) => AppLockController(ref),
);
