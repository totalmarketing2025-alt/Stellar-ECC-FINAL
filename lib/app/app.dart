import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme/stellar_theme.dart';
import 'router.dart';
import '../presentation/state/relay_listener.dart';
import '../presentation/state/app_providers.dart';
import '../presentation/state/security_providers.dart';
import '../core/calls/call_platform_bridge.dart';

class StellarEccApp extends ConsumerStatefulWidget {
  const StellarEccApp({super.key});

  @override
  ConsumerState<StellarEccApp> createState() => _StellarEccAppState();
}

class _StellarEccAppState extends ConsumerState<StellarEccApp> {
  StreamSubscription<CallPlatformAction>? _callActionSubscription;
  CallPlatformAction? _pendingNativeCallAction;
  bool _pendingNativeActionScheduled = false;

  static const MethodChannel _wantedModeNavigationChannel =
      MethodChannel('ecc.stellar.app/wanted_mode_navigation');
  static const MethodChannel _wantedModeMonitorChannel =
      MethodChannel('ecc.stellar.app/wanted_mode_monitor');

  @override
  void initState() {
    super.initState();

    _wantedModeNavigationChannel.setMethodCallHandler((call) async {
      if (call.method == 'openSecurity') {
        await _consumePendingWantedSecurityNavigation();
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(_consumePendingWantedSecurityNavigation());
      }
    });

    _callActionSubscription =
        ref.read(callPlatformBridgeProvider).actions.listen((action) {
      final nickname = ref.read(localNicknameProvider);
      if (nickname == null || nickname.isEmpty) {
        _pendingNativeCallAction = action;
        return;
      }
      _dispatchNativeCallAction(action);
    });
  }

  Future<void> _consumePendingWantedSecurityNavigation() async {
    try {
      final pending = await _wantedModeMonitorChannel
              .invokeMethod<bool>('takePendingWantedSecurityNavigation') ??
          false;

      if (!mounted || !pending) return;

      ref.read(appRouterProvider).go('/security');
    } catch (_) {
      // The pending native navigation can be retried on the next launch.
    }
  }

  void _dispatchNativeCallAction(CallPlatformAction action) {
    final nickname = ref.read(localNicknameProvider);
    if (nickname == null || nickname.isEmpty) {
      _pendingNativeCallAction = action;
      return;
    }

    // One owner handles the native action; the coordinator no longer
    // subscribes independently to the broadcast stream.
    unawaited(
      ref.read(callCoordinatorProvider).handlePlatformAction(action),
    );

    if (action.action != 'answer' ||
        action.callId.isEmpty ||
        action.chatId == null ||
        action.chatId!.isEmpty) {
      return;
    }

    final encodedChatId = Uri.encodeComponent(action.chatId!);
    final route = action.kind == 'video'
        ? '/call/video/$encodedChatId?incoming=1'
        : '/call/voice/$encodedChatId?incoming=1';

    ref.read(appRouterProvider).go(route);
  }

  void _schedulePendingNativeAction() {
    if (_pendingNativeCallAction == null ||
        _pendingNativeActionScheduled) {
      return;
    }

    _pendingNativeActionScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pendingNativeActionScheduled = false;
      if (!mounted) return;

      final nickname = ref.read(localNicknameProvider);
      if (nickname == null || nickname.isEmpty) return;

      final action = _pendingNativeCallAction;
      if (action == null) return;

      _pendingNativeCallAction = null;
      _dispatchNativeCallAction(action);
    });
  }

  @override
  void dispose() {
    _callActionSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Keep incoming relay processing alive after the local nickname
    // has been restored by the splash screen.
    ref.watch(relayListenerProvider);

    // Call services require a restored local nickname. Do not create the
    // coordinator during the initial build while the splash is loading it.
    final nickname = ref.watch(localNicknameProvider);
    if (nickname != null && nickname.isNotEmpty) {
      ref.watch(callCoordinatorProvider);
      _schedulePendingNativeAction();
    }

    final router = ref.watch(appRouterProvider);
    final wantedModeEnabled = ref.watch(wantedModeWipeEnabledProvider);

    return MaterialApp.router(
      title: 'Stellar ECC',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      darkTheme: StellarTheme.dark(),
      theme: StellarTheme.dark(), // Deep Space theme is dark-only, per spec
      routerConfig: router,
      builder: (context, child) {
        return Stack(
          fit: StackFit.expand,
          children: [
            child ?? const SizedBox.shrink(),
            if (wantedModeEnabled)
              const _WantedModePurpleBottomGlow(),
          ],
        );
      },
    );
  }
}



// WANTED_MODE_PURPLE_BOTTOM_GLOW_V1
class _WantedModePurpleBottomGlow extends StatefulWidget {
  const _WantedModePurpleBottomGlow();

  @override
  State<_WantedModePurpleBottomGlow> createState() =>
      _WantedModePurpleBottomGlowState();
}

class _WantedModePurpleBottomGlowState
    extends State<_WantedModePurpleBottomGlow>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      height: 22,
      child: IgnorePointer(
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, _) {
            final intensity = 0.25 + (_controller.value * 0.15);
            const purple = Color(0xFF9B4DFF);

            return Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.transparent,
                    purple.withOpacity(intensity * 0.35),
                    purple.withOpacity(intensity),
                  ],
                  stops: const [0.0, 0.55, 1.0],
                ),
                boxShadow: [
                  BoxShadow(
                    color: purple.withOpacity(intensity * 0.25),
                    blurRadius: 12,
                    spreadRadius: 1,
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
