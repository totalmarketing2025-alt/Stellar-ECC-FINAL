import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme/stellar_theme.dart';
import 'router.dart';
import '../presentation/state/relay_listener.dart';
import '../presentation/state/app_providers.dart';
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

  @override
  void initState() {
    super.initState();
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

    return MaterialApp.router(
      title: 'Stellar ECC',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      darkTheme: StellarTheme.dark(),
      theme: StellarTheme.dark(), // Deep Space theme is dark-only, per spec
      routerConfig: router,
    );
  }
}
