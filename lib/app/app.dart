import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme/stellar_theme.dart';
import 'router.dart';
import '../presentation/state/relay_listener.dart';

class StellarEccApp extends ConsumerWidget {
  const StellarEccApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Keep incoming relay processing alive after the local nickname
    // has been restored by the splash screen.
    ref.watch(relayListenerProvider);

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
