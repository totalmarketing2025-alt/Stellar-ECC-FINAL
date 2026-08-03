import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/stellar_theme.dart';

class RecoverySetupScreen extends StatelessWidget {
  const RecoverySetupScreen({super.key});

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
            const Icon(Icons.backup_outlined, color: StellarColors.accentPurple, size: 40),
            const SizedBox(height: 16),
            const Text('Account recovery', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700)),
            const SizedBox(height: 12),
            const Text(
              'This is entirely optional, and off by default. Skip this and losing '
              'your device means losing your account — that\'s the tradeoff for '
              'not requiring a phone number or email. If you set up recovery, your '
              'passphrase encrypts your identity key before it ever leaves this '
              'device — Stellar ECC\'s servers never see it.',
              style: TextStyle(color: StellarColors.textSecondary, height: 1.5),
            ),
            const Spacer(),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: () {}, // opens passphrase setup + export flow (Module 7)
                child: const Text('Set up recovery'),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () => context.go('/onboarding/app-lock'),
                child: const Text('Skip for now'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
