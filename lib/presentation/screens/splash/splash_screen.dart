import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/stellar_theme.dart';
import '../../state/app_providers.dart';
import '../../state/app_lock_controller.dart';

class SplashScreen extends ConsumerStatefulWidget {
  const SplashScreen({super.key});

  @override
  ConsumerState<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends ConsumerState<SplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  )..forward();

  @override
  void initState() {
    super.initState();
    _resolveDestination();
  }

  Future<void> _resolveDestination() async {
    final identityStore = ref.read(identityKeyStoreProvider);
    await identityStore.initializeIfAbsent();

    await ref.read(localNicknameProvider.notifier).load();
    final nickname = ref.read(localNicknameProvider);

    await Future.delayed(const Duration(milliseconds: 700));

    if (!mounted) return;

    if (nickname == null) {
      context.go('/onboarding/welcome');
      return;
    }

    final keyStore = ref.read(platformKeyStoreProvider);
    final hasPin = await keyStore.hasPin();

    final lockController = ref.read(appLockControllerProvider);
    await lockController.loadEnabledState();

    final biometricEnabled =
        await lockController.isBiometricLockEnabled();

    if (biometricEnabled) {
      final authenticated = await lockController.authenticate();

      if (!mounted) return;

      if (authenticated) {
        context.go('/chats');
        return;
      }

      // Biometric was cancelled/failed. Preserve the existing PIN
      // fallback instead of unlocking the app automatically.
      if (hasPin) {
        context.go('/unlock');
      }
      return;
    }

    if (hasPin) {
      context.go('/unlock');
      return;
    }

    ref.read(isUnlockedProvider.notifier).state = true;
    context.go('/chats');
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: StellarColors.bgPrimary,
      body: Center(
        child: FadeTransition(
          opacity: _controller,
          child: ScaleTransition(
            scale: Tween(begin: 0.9, end: 1.0).animate(
              CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic),
            ),
            child: Container(
              width: 96,
              height: 96,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                gradient: StellarColors.stellarGradient,
              ),
              child: const Icon(Icons.auto_awesome, color: Colors.white, size: 40),
            ),
          ),
        ),
      ),
    );
  }
}
