import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/stellar_theme.dart';

class RecoverySetupScreen extends ConsumerWidget {
  const RecoverySetupScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      backgroundColor: StellarColors.bgPrimary,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(
                Icons.backup_outlined,
                color: StellarColors.accentPurple,
                size: 40,
              ),
              const SizedBox(height: 16),
              const Text(
                'Account recovery',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'Recovery is completely optional and is off by default.',
                style: TextStyle(
                  color: StellarColors.textSecondary,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'Without recovery, losing this device means losing access '
                'to your account. If you enable recovery, your passphrase '
                'protects your identity key before it leaves this device.',
                style: TextStyle(
                  color: StellarColors.textSecondary,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'Stellar ECC servers never receive your recovery passphrase.',
                style: TextStyle(
                  color: StellarColors.textSecondary,
                  height: 1.5,
                ),
              ),
              const Spacer(),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: () {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text(
                          'Recovery setup will be available in the next module.',
                        ),
                      ),
                    );
                  },
                  child: const Text('Set up recovery'),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () {
                    context.go('/onboarding/app-lock');
                  },
                  child: const Text('Skip for now'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
