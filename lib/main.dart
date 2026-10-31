import 'dart:async';
import 'dart:developer' as developer;
import 'core/network/push_background_handler.dart';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'core/security/platform_key_store.dart';
import 'app/app.dart';
import 'app/firebase_options.dart';
import 'core/storage/database.dart';
import 'core/storage/providers.dart';
import 'core/storage/expiry_sweeper.dart';
import 'core/network/push_handler.dart';
import 'presentation/state/app_providers.dart';




const MethodChannel _wantedWipeChannel =
    MethodChannel('ecc.stellar.app/wanted_mode_monitor');

Future<void> _wipeLocalFilesAndKeys() async {
  // Поддршка-директориумот ја содржи SQLCipher базата и локалните медиуми.
  final support = await getApplicationSupportDirectory();
  if (await support.exists()) {
    await support.delete(recursive: true);
  }

  // Ги отстрануваме и привремените локални прилози/cache.
  final temporary = await getTemporaryDirectory();
  if (await temporary.exists()) {
    await temporary.delete(recursive: true);
  }

  // Ги брише PIN, identity, DB master key и сите други app Secure Storage записи.
  // Не го брише FCM token-от, кој го чува Firebase SDK.
  await PlatformKeyStore().wipeAll();
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Ова мора да се провери пред Firebase.initializeApp() и пред отворање DB.
  final wipePendingAtStartup =
      await _wantedWipeChannel.invokeMethod<bool>('hasPendingLocalWipe') ??
          false;

  if (wipePendingAtStartup) {
    await _wipeLocalFilesAndKeys();
    await _wantedWipeChannel.invokeMethod<bool>('completeLocalWipe');
    return;
  }

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
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
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

  var localWipeInProgress = false;
  var relayDisconnected = false;
  var containerDisposed = false;
  var databaseClosed = false;

  Future<void> performWantedModeLocalWipe() async {
    if (localWipeInProgress) return;
    localWipeInProgress = true;

    try {
      // Прво запираме локални задачи и Relay socket.
      sweeper.stop();

      if (!relayDisconnected) {
        await container.read(relayClientProvider).disconnect();
        relayDisconnected = true;
      }

      // Состојбата се памети за повторен обид ако подоцна нешто не успее.
      if (!containerDisposed) {
        container.dispose();
        containerDisposed = true;
      }

      if (!databaseClosed) {
        database.close();
        databaseClosed = true;
      }

      await _wipeLocalFilesAndKeys();

      final completed =
          await _wantedWipeChannel.invokeMethod<bool>('completeLocalWipe');

      if (completed != true) {
        throw StateError('Native local wipe completion was not confirmed.');
      }
    } catch (error, stack) {
      // Дозволуваме следниот native сигнал повторно да го продолжи wipe-от.
      localWipeInProgress = false;

      developer.log(
        'Wanted Mode local wipe failed; retry remains possible.',
        name: 'stellar_ecc.wipe',
        error: error,
        stackTrace: stack,
      );

      rethrow;
    }
  }

  _wantedWipeChannel.setMethodCallHandler((call) async {
    if (call.method == 'wantedModeWipeRequested') {
      await performWantedModeLocalWipe();
      return true;
    }
    throw MissingPluginException(
      'Unknown Wanted Mode method: ${call.method}',
    );
  });

  // Покрива истекување што се случило додека Flutter ги отворал ресурсите.
  final wipePendingAfterOpen =
      await _wantedWipeChannel.invokeMethod<bool>('hasPendingLocalWipe') ??
          false;
  if (wipePendingAfterOpen) {
    await performWantedModeLocalWipe();
    return;
  }

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
      final wipePendingBeforeDirectorySync =
          await _wantedWipeChannel.invokeMethod<bool>(
                'hasPendingLocalWipe',
              ) ??
              false;

      if (!wipePendingBeforeDirectorySync) {
        final sessionManager = container.read(sessionManagerProvider);
        final directoryClient = container.read(directoryClientProvider);

        await sessionManager.ensureMinimumPreKeys();

        final wipePendingAfterPreKeys =
            await _wantedWipeChannel.invokeMethod<bool>(
                  'hasPendingLocalWipe',
                ) ??
                false;

        if (!wipePendingAfterPreKeys) {
          final bundle = await sessionManager.buildLocalDirectoryBundle();

          final wipePendingBeforeUpdate =
              await _wantedWipeChannel.invokeMethod<bool>(
                    'hasPendingLocalWipe',
                  ) ??
                  false;

          if (!wipePendingBeforeUpdate) {
            try {
              await directoryClient.updateBundle(
                nickname: nickname,
                preKeyBundle: bundle,
              );
            } catch (e) {
              final text = e.toString();
              if (text.contains('404') || text.contains('User not found')) {
                final wipePendingBeforeRegister =
                    await _wantedWipeChannel.invokeMethod<bool>(
                          'hasPendingLocalWipe',
                        ) ??
                        false;

                if (!wipePendingBeforeRegister) {
                  await directoryClient.register(
                    nickname: nickname,
                    preKeyBundle: bundle,
                  );
                }
              } else {
                rethrow;
              }
            }

            developer.log(
              'Startup Signal bundle synchronization completed.',
              name: 'stellar_ecc.directory',
            );
          }
        }
      }
    }
  } catch (e, st) {
    developer.log(
      'Startup Signal bundle synchronization failed.',
      name: 'stellar_ecc.directory',
      error: e,
      stackTrace: st,
    );
  }

  final wipePendingBeforePush =
      await _wantedWipeChannel.invokeMethod<bool>('hasPendingLocalWipe') ??
          false;
  if (wipePendingBeforePush) {
    await performWantedModeLocalWipe();
    return;
  }

  // Request Android runtime permissions once, after all wipe guards.
  try {
    await _wantedWipeChannel.invokeMethod('requestStartupPermissions');
  } catch (e, st) {
    developer.log(
      'Startup permission request failed; continuing without blocking app.',
      name: 'stellar_ecc.startup',
      error: e,
      stackTrace: st,
    );
  }

  if (firebaseAvailable) {
    FirebaseMessaging.onBackgroundMessage(
      firebaseMessagingBackgroundHandler,
    );

    try {
      final pushHandler = PushHandler(
        relayClient: container.read(relayClientProvider),
        messaging: FirebaseMessaging.instance,
        directoryClient: container.read(directoryClientProvider),
        sessionManager: container.read(sessionManagerProvider),
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

  // Android 14+ requires separate special access for full-screen call UI.
  try {
    await _wantedWipeChannel.invokeMethod('requestFullScreenCallAccess');
  } catch (e, st) {
    developer.log(
      'Full-screen call access request failed; continuing.',
      name: 'stellar_ecc.startup',
      error: e,
      stackTrace: st,
    );
  }

  // The live Relay endpoint is configured in
  // presentation/state/app_providers.dart. Keep this note synchronized
  // with the active configuration; do not assume Relay is unavailable
  // based on an outdated placeholder URL. Onboarding, local key generation, navigation,
  // the Security Center, and local encrypted storage all work fully
  // offline right now.
  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const StellarEccApp(),
    ),
  );
}
