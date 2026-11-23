import 'dart:async';
import 'dart:math' show cos;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme/stellar_theme.dart';
import 'router.dart';
import '../presentation/state/relay_listener.dart';
import '../presentation/state/incoming_message_pulse.dart';
import '../presentation/state/app_providers.dart';
import '../presentation/state/security_providers.dart';
import '../core/calls/call_coordinator.dart';
import '../core/calls/group_call_coordinator.dart';
import '../core/calls/call_platform_bridge.dart';
import '../domain/models/call_session.dart';
import '../domain/models/group_call_room.dart';

class StellarEccApp extends ConsumerStatefulWidget {
  const StellarEccApp({super.key});

  @override
  ConsumerState<StellarEccApp> createState() => _StellarEccAppState();
}

class _StellarEccAppState extends ConsumerState<StellarEccApp>
    with WidgetsBindingObserver {
  Timer? _guardAccountTimer;
  bool _guardAccountCheckInProgress = false;
  StreamSubscription<CallPlatformAction>? _callActionSubscription;
  CallPlatformAction? _pendingNativeCallAction;
  bool _pendingNativeActionScheduled = false;
  StreamSubscription<CallSession?>? _callSessionSubscription;
  StreamSubscription<GroupCallRoom?>? _groupCallSubscription;
  final Set<String> _incomingNavigationPendingCallIds = <String>{};

  static const MethodChannel _wantedModeNavigationChannel =
      MethodChannel('ecc.stellar.app/wanted_mode_navigation');
  static const MethodChannel _wantedModeMonitorChannel =
      MethodChannel('ecc.stellar.app/wanted_mode_monitor');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _guardAccountTimer = Timer.periodic(const Duration(minutes: 2), (_) {
      unawaited(_checkGuardAccountRevocation());
    });

    _wantedModeNavigationChannel.setMethodCallHandler((call) async {
      if (call.method == 'openSecurity') {
        await _consumePendingWantedSecurityNavigation();
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(_consumePendingWantedSecurityNavigation());
        unawaited(_checkGuardAccountRevocation());
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

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_checkGuardAccountRevocation());
    }
  }

  Future<void> _checkGuardAccountRevocation() async {
    if (!mounted || _guardAccountCheckInProgress) return;
    final nickname = ref.read(localNicknameProvider);
    if (nickname == null || nickname.isEmpty) return;
    _guardAccountCheckInProgress = true;
    try {
      final revoked = await ref.read(guardCaseServiceProvider)
          .isAccountRevoked(nickname)
          .timeout(const Duration(seconds: 15));
      if (!revoked || !mounted ||
          ref.read(localNicknameProvider) != nickname) return;
      // Persist the native pending marker before any destructive action. A
      // restart after a partial wipe will resume cleanup before opening DB.
      try {
        final armed = await _wantedModeMonitorChannel.invokeMethod<bool>(
          'requestVerifiedGuardWipe',
        );
        if (armed != true) throw StateError('Guard wipe marker not persisted');
        ref.read(isUnlockedProvider.notifier).state = false;
        // MainActivity signals main() to perform the full wipe, then restarts
        // the Activity on the welcome page. Do not wipe twice here.
      } on MissingPluginException {
        // Fallback for platforms where the Android marker is unavailable.
        await ref.read(wantedModeControllerProvider).wipeAndLock();
        if (mounted) ref.read(appRouterProvider).go('/onboarding/welcome');
      }
    } catch (_) {
      // Offline devices retry on resume and at the periodic interval. A
      // network failure must never delete someone's local identity.
    } finally {
      _guardAccountCheckInProgress = false;
    }
  }

  Future<void> _consumePendingWantedSecurityNavigation() async {
    try {
      // Never consume the native request before authentication. The ordinary
      // PIN screen and the incoming-call flow must retain their own priority.
      if (!mounted || !ref.read(isUnlockedProvider)) return;
      final coordinator = ref.read(callCoordinatorProvider);
      final activeCall = coordinator.activeSession;
      if (activeCall != null &&
          activeCall.state == CallState.ringing &&
          coordinator.lastSignal?.type == 'offer') return;

      final navigation = await _wantedModeMonitorChannel
          .invokeMapMethod<String, dynamic>(
        'takePendingWantedSecurityNavigation',
      );

      if (!mounted || !ref.read(isUnlockedProvider) ||
          navigation?['pending'] != true) return;

      final id = navigation?['challengeId']?.toString() ?? '';
      final query = id.isEmpty
          ? '?wanted=1'
          : '?wanted=1&challengeId=${Uri.encodeQueryComponent(id)}';
      ref.read(appRouterProvider).go('/security$query');
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

    if (action.action == 'open_incoming_call') {
      if (action.callId.isEmpty) return;
      ref.read(pendingIncomingCallNavigationProvider.notifier).state =
          action.callId;
      _navigateToPendingIncomingCall();
      return;
    }

    // One owner handles the native action; the coordinator no longer
    // subscribes independently to the broadcast stream.
    unawaited(
      ref.read(callCoordinatorProvider).handlePlatformAction(action),
    );

    final activeCall = ref.read(callCoordinatorProvider).activeSession;
    if (activeCall == null || activeCall.callId != action.callId ||
        activeCall.state == CallState.ended || activeCall.state == CallState.failed) return;

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

  void _navigateToPendingIncomingCall() {
    if (!mounted || !ref.read(isUnlockedProvider)) return;
    final callId = ref.read(pendingIncomingCallNavigationProvider);
    if (callId == null) return;
    final coordinator = ref.read(callCoordinatorProvider);
    final session = coordinator.activeSession;
    final offer = coordinator.lastSignal;
    if (session == null || session.callId != callId ||
        session.state != CallState.ringing ||
        offer?.type != 'offer' || offer?.session.callId != callId) {
      return;
    }
    ref.read(pendingIncomingCallNavigationProvider.notifier).state = null;
    final kind = session.kind == CallKind.video ? 'video' : 'voice';
    ref.read(appRouterProvider).go(
      '/call/$kind/${Uri.encodeComponent(session.chatId)}?incoming=1',
    );
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

  void _ensureIncomingCallListener(CallCoordinator coordinator) {
    if (_callSessionSubscription != null) return;

    _callSessionSubscription = coordinator.sessionStream.listen((session) {
      if (session == null || session.state == CallState.ended ||
          session.state == CallState.failed) {
        ref.read(pendingIncomingCallNavigationProvider.notifier).state = null;
      }
      _navigateToPendingIncomingCall();
      if (session == null || session.state == CallState.ended ||
          session.state == CallState.failed) {
        unawaited(_consumePendingWantedSecurityNavigation());
      }
      _scheduleIncomingCallNavigation(coordinator, session);
    });

    // Do not miss an offer that arrived before this listener was attached.
    _scheduleIncomingCallNavigation(coordinator, coordinator.activeSession);
  }

  void _ensureGroupCallListener(GroupCallCoordinator coordinator) {
    if (_groupCallSubscription != null) return;
    _groupCallSubscription = coordinator.roomStream.listen((room) {
      if (room?.isIncoming == true) _scheduleGroupInvitationNavigation(room!);
    });
    final existing = coordinator.activeRoom;
    if (existing?.isIncoming == true) {
      _scheduleGroupInvitationNavigation(existing!);
    }
  }

  void _scheduleGroupInvitationNavigation(GroupCallRoom room) {
    if (!mounted || !ref.read(isUnlockedProvider)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !ref.read(isUnlockedProvider)) return;
      final active = ref.read(groupCallCoordinatorProvider).activeRoom;
      if (active == null || active.roomId != room.roomId ||
          !active.isIncoming) return;
      final router = ref.read(appRouterProvider);
      final route = '/group/call/${Uri.encodeComponent(room.chatId)}';
      if (router.routeInformationProvider.value.uri.path != route) {
        router.go('$route?incoming=1');
      }
    });
  }

  void _scheduleIncomingCallNavigation(
    CallCoordinator coordinator,
    CallSession? session,
  ) {
    if (session == null ||
        session.state != CallState.ringing ||
        coordinator.lastSignal?.type != 'offer' ||
        _incomingNavigationPendingCallIds.contains(session.callId)) {
      return;
    }

    _incomingNavigationPendingCallIds.add(session.callId);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        _incomingNavigationPendingCallIds.remove(session.callId);
        return;
      }

      final active = coordinator.activeSession;
      if (active == null ||
          active.callId != session.callId ||
          active.state != CallState.ringing ||
          coordinator.lastSignal?.type != 'offer') {
        _incomingNavigationPendingCallIds.remove(session.callId);
        return;
      }

      if (!ref.read(isUnlockedProvider)) {
        _incomingNavigationPendingCallIds.remove(session.callId);
        return;
      }

      final encodedChatId = Uri.encodeComponent(session.chatId);
      final route = session.kind == CallKind.video
          ? '/call/video/$encodedChatId?incoming=1'
          : '/call/voice/$encodedChatId?incoming=1';

      final router = ref.read(appRouterProvider);
      final currentPath = router.routeInformationProvider.value.uri.path;

      if (currentPath != route.split('?').first) {
        router.go(route);
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _guardAccountTimer?.cancel();
    _callActionSubscription?.cancel();
    _callSessionSubscription?.cancel();
    _groupCallSubscription?.cancel();
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
      final coordinator = ref.watch(callCoordinatorProvider);
      _ensureIncomingCallListener(coordinator);
      final groupCoordinator = ref.watch(groupCallCoordinatorProvider);
      _ensureGroupCallListener(groupCoordinator);
      _schedulePendingNativeAction();
    }

    ref.listen<bool>(isUnlockedProvider, (previous, next) {
      if (next) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _navigateToPendingIncomingCall();
          final groupRoom = ref.read(groupCallCoordinatorProvider).activeRoom;
          if (groupRoom?.isIncoming == true) {
            _scheduleGroupInvitationNavigation(groupRoom!);
          }
          unawaited(_consumePendingWantedSecurityNavigation());
        });
      }
    });

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
            const _StellarIncomingEdgeGlow(),
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


/// Two soft purple edge pulses for newly persisted incoming messages.
/// This foreground effect deliberately does not wake or unlock the device.
class _StellarIncomingEdgeGlow extends StatefulWidget {
  const _StellarIncomingEdgeGlow();

  @override
  State<_StellarIncomingEdgeGlow> createState() =>
      _StellarIncomingEdgeGlowState();
}

class _StellarIncomingEdgeGlowState extends State<_StellarIncomingEdgeGlow>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2200),
  );

  @override
  void initState() {
    super.initState();
    stellarIncomingMessagePulse.addListener(_onIncomingMessage);
  }

  void _onIncomingMessage() {
    if (mounted) _pulse.forward(from: 0);
  }

  @override
  void dispose() {
    stellarIncomingMessagePulse.removeListener(_onIncomingMessage);
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: IgnorePointer(
        child: AnimatedBuilder(
          animation: _pulse,
          builder: (context, _) {
            if (!_pulse.isAnimating) return const SizedBox.shrink();
            final phase = _pulse.value * 4 * 3.141592653589793;
            final strength = (0.5 - 0.5 * mathCos(phase)) *
                (1.0 - _pulse.value);
            return Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _edge(strength, true),
                _edge(strength, false),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _edge(double strength, bool left) {
    return Container(
      width: 15,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: left ? Alignment.centerLeft : Alignment.centerRight,
          end: left ? Alignment.centerRight : Alignment.centerLeft,
          colors: [
            const Color(0xFF8B5CF6).withOpacity(0.52 * strength),
            const Color(0xFF8B5CF6).withOpacity(0.18 * strength),
            Colors.transparent,
          ],
        ),
      ),
    );
  }
}

double mathCos(double radians) {
  // Dart's math library provides the cosine used for a smooth two-pulse fade.
  return cos(radians);
}
