import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/stellar_theme.dart';
import '../../state/app_providers.dart';

class IdentityCreationScreen extends ConsumerStatefulWidget {
  const IdentityCreationScreen({super.key});

  @override
  ConsumerState<IdentityCreationScreen> createState() =>
      _IdentityCreationScreenState();
}

class _IdentityCreationScreenState
    extends ConsumerState<IdentityCreationScreen> {
  bool _started = false;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    if (_started) return;
    _started = true;

    try {
      final sessionManager = ref.read(sessionManagerProvider);

      await ref.read(identityKeyStoreProvider).initializeIfAbsent();

      await Future<void>.delayed(const Duration(milliseconds: 1400));

      if (!mounted) return;
      context.go('/onboarding/nickname');
    } catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Identity creation failed: $e'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: StellarColors.bgPrimary,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(
                width: 56,
                height: 56,
                child: CircularProgressIndicator(
                  strokeWidth: 3,
                  valueColor: AlwaysStoppedAnimation(
                    StellarColors.accentPurple,
                  ),
                ),
              ),
              const SizedBox(height: 24),
              const Text(
                'Forging your identity…',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Generating your private cryptographic keys, on this device only.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: StellarColors.textSecondary,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
