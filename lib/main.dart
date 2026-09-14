import 'dart:developer' as developer;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_core/firebase_core.dart';

import 'app/app.dart';
import 'app/firebase_options.dart';
import 'core/storage/database.dart';
import 'core/storage/providers.dart';
import 'core/storage/expiry_sweeper.dart';
import 'core/network/push_handler.dart';
import 'presentation/state/app_providers.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Push notifications: FCM (Android) / APNs bridge (iOS). Payloads are
  // opaque wake pings only — see core/network/push_handler.dart.
  //
  // Wrapped in try/catch deliberately: with the placeholder
  // google-services.json / GoogleService-Info.plist checked in (see
  // app/firebase_options.dart's comment), Firebase.initializeApp() or the
  // token-fetch inside PushHandler can throw against a project that
  // doesn't really exist. That's expected until you run
  // `flutterfire configure` for real — it should degrade to "push
  // notifications don't work yet," not "app won't launch."
  var firebaseAvailable = true;
  try {
    await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  } catch (e, st) {
    firebaseAvailable = false;
    developer.log(
      'Firebase init failed — continuing without push notifications. '
      'Run `flutterfire configure` against a real project to enable this.',
      name: 'stellar_ecc.startup',
      error: e,
      stackTrace: st,
    );
  }

  // Open (or create) the ephemeral, TTL-bounded, encrypted-at-rest message
  // database. Encryption key itself is wrapped via platform Keystore /
  // Secure Enclave — see core/security/platform_key_store.dart.
  final database = await StellarDatabase.open();

  // Background + foreground TTL sweeper — enforces "messages disappear"
  // at the app layer, independent of the OS scheduler's exact timing.
  final sweeper = ExpirySweeper(database);
  sweeper.start();

  // Build the ProviderContainer up front (rather than letting ProviderScope
  // create an implicit one) so main() and the widget tree share the exact
  // same RelayClient instance — avoids the bug of push registration and
  // the in-app relay connection silently using two different sockets.
  final container = ProviderContainer(
    overrides: [databaseProvider.overrideWithValue(database)],
  );



  // Startup Signal bundle synchronization.
  // Keeps Directory current after prekey consumption/restart.
  try {
    final nicknameBytes = await container
        .read(platformKeyStoreProvider)
        .readSecret('stellar.local_nickname');

    final nickname = nicknameBytes == null
        ? null
        : String.fromCharCodes(nicknameBytes).trim();

    if (nickname != null && nickname.isNotEmpty) {
      final sessionManager = container.read(sessionManagerProvider);
      final directoryClient = container.read(directoryClientProvider);

      await sessionManager.ensureMinimumPreKeys();

      final bundle = await sessionManager.buildLocalDirectoryBundle();

      try {
        await directoryClient.updateBundle(
          nickname: nickname,
          preKeyBundle: bundle,
        );
      } catch (e) {
        final text = e.toString();
        if (text.contains('404') || text.contains('User not found')) {
          await directoryClient.register(
            nickname: nickname,
            preKeyBundle: bundle,
          );
        } else {
          rethrow;
        }
      }

      developer.log(
        'Startup Signal bundle synchronized.',
        name: 'stellar_ecc.directory',
      );
    }
  } catch (e, st) {
    developer.log(
      'Startup Signal bundle synchronization failed.',
      name: 'stellar_ecc.directory',
      error: e,
      stackTrace: st,
    );
  }

  if (firebaseAvailable) {
    try {
      final pushHandler = PushHandler(
        relayClient: container.read(relayClientProvider),
        messaging: FirebaseMessaging.instance,
        directoryClient: container.read(directoryClientProvider),
        getLocalNickname: () async {
          final bytes = await container
              .read(platformKeyStoreProvider)
              .readSecret('stellar.local_nickname');
          return bytes == null ? null : String.fromCharCodes(bytes);
        },
      );
      await pushHandler.initialize();

      container.read(localNicknameProvider.notifier).addListener((nickname) {
        if (nickname != null && nickname.isNotEmpty) {
          pushHandler.registerCurrentToken().catchError((error, stack) {
            developer.log(
              'Push token registration failed after nickname restore.',
              name: 'stellar_ecc.push',
              error: error,
              stackTrace: stack,
            );
          });
        }
      });
    } catch (e, st) {
      // Same reasoning as above — a placeholder Firebase project or no
      // network at startup shouldn't block the app from opening.
      developer.log(
        'Push handler init failed — continuing without push notifications.',
        name: 'stellar_ecc.startup',
        error: e,
        stackTrace: st,
      );
    }
  }

  // NOTE for whoever's testing this build: there is no live relay server
  // deployed at the placeholder wss://relay.stellarecc.example URL (see
  // Phase 9 — it's a designed-but-not-deployed reference implementation).
  // Sending a message will attempt to connect, fail, and the message will
  // show status "failed" in the chat bubble rather than crashing anything
  // — that's the RelayClient/ChatRepository error path working as
  // intended, not a bug. Onboarding, local key generation, navigation,
  // the Security Center, and local encrypted storage all work fully
  // offline right now.
  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const StellarEccApp(),
    ),
  );
}


