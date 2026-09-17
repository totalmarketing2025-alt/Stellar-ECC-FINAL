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

  @override
  void initState() {
    super.initState();
    _callActionSubscription = ref.read(callPlatformBridgeProvider).actions.listen((action) {
      if (action.action != 'answer' || action.callId.isEmpty || action.chatId == null) {
        return;
      }

      final encodedChatId = Uri.encodeComponent(action.chatId!);
      final route = action.kind == 'video'
          ? '/call/video/$encodedChatId?incoming=1'
          : '/call/voice/$encodedChatId?incoming=1';

      ref.read(appRouterProvider).go(route);
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
    ref.watch(callCoordinatorProvider);

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
