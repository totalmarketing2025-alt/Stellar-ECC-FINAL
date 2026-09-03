import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/stellar_theme.dart';
import '../../state/app_providers.dart';

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
    // Restore session state (identity present? nickname registered? app
    // lock required?) while the splash animation plays, so there is no
    // separate loading spinner after this screen.
    final identityStore = ref.read(identityKeyStoreProvider);
    await identityStore.initializeIfAbsent();

    await ref.read(localNicknameProvider.notifier).load();
    final nickname = ref.read(localNicknameProvider);
    await Future.delayed(const Duration(milliseconds: 700)); // let the animation finish

    if (!mounted) return;

    if (nickname == null) {
      context.go('/onboarding/welcome');
    } else {
      context.go('/chats');
    }
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
