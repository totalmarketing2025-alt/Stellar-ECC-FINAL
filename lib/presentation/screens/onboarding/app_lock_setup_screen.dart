import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:local_auth/local_auth.dart';

import '../../../core/theme/stellar_theme.dart';
import '../../state/app_providers.dart';

class AppLockSetupScreen extends ConsumerStatefulWidget {
  const AppLockSetupScreen({super.key});

  @override
  ConsumerState<AppLockSetupScreen> createState() => _AppLockSetupScreenState();
}

class _AppLockSetupScreenState extends ConsumerState<AppLockSetupScreen> {
  final _localAuth = LocalAuthentication();
  String? _status;

  Future<void> _enableBiometrics() async {
    final canCheck = await _localAuth.canCheckBiometrics;
    if (!canCheck) {
      setState(() => _status = 'Biometrics not available on this device — set a PIN instead.');
      return;
    }
    final ok = await _localAuth.authenticate(
      localizedReason: 'Confirm biometric unlock for Stellar ECC',
      options: const AuthenticationOptions(biometricOnly: false, stickyAuth: true),
    );
    if (ok) {
      ref.read(isUnlockedProvider.notifier).state = true;
      if (mounted) context.go('/chats');
    } else {
      setState(() => _status = 'Authentication was not completed.');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: StellarColors.bgPrimary,
      appBar: AppBar(backgroundColor: Colors.transparent, elevation: 0),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.fingerprint, color: StellarColors.accentBlue, size: 40),
            const SizedBox(height: 16),
            const Text('Protect your messages', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700)),
            const SizedBox(height: 12),
            const Text(
              'Require Face ID / Touch ID / fingerprint (or a PIN) to open Stellar ECC.',
              style: TextStyle(color: StellarColors.textSecondary),
            ),
            if (_status != null) ...[
              const SizedBox(height: 16),
              Text(_status!, style: const TextStyle(color: StellarColors.danger)),
            ],
            const Spacer(),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _enableBiometrics,
                child: const Text('Enable biometric lock'),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: () {
                  ref.read(isUnlockedProvider.notifier).state = true;
                  context.go('/chats');
                },
                child: const Text('Set a PIN instead'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
