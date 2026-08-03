import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/stellar_theme.dart';
import '../../state/app_providers.dart';

class IdentityCreationScreen extends ConsumerStatefulWidget {
  const IdentityCreationScreen({super.key});

  @override
  ConsumerState<IdentityCreationScreen> createState() => _IdentityCreationScreenState();
}

class _IdentityCreationScreenState extends ConsumerState<IdentityCreationScreen> {
  @override
  void initState() {
    super.initState();
    _generateIdentity();
  }

  Future<void> _generateIdentity() async {
    final identityStore = ref.read(identityKeyStoreProvider);
    await identityStore.initializeIfAbsent(); // real X25519 identity key pair generation

    // Masks real crypto latency behind a short, deliberate animation beat
    // (Phase 5 onboarding spec) rather than a bare spinner.
    await Future.delayed(const Duration(milliseconds: 1400));

    if (mounted) context.go('/onboarding/nickname');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: StellarColors.bgPrimary,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 56,
              height: 56,
              child: CircularProgressIndicator(
                strokeWidth: 3,
                valueColor: AlwaysStoppedAnimation(StellarColors.accentPurple),
              ),
            ),
            const SizedBox(height: 24),
            const Text('Forging your identity…', style: TextStyle(fontSize: 16)),
            const SizedBox(height: 8),
            const Text(
              'Generating your private cryptographic keys, on this device only.',
              style: TextStyle(color: StellarColors.textSecondary, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}
