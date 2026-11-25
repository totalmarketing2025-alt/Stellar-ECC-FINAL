import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';
import 'core/network/push_background_handler.dart';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'core/security/platform_key_store.dart';
import 'core/media/media_attachment_service.dart';
import 'core/stories/story_temp_files.dart';
import 'app/app.dart';
import 'app/firebase_options.dart';
import 'core/storage/database.dart';
import 'core/storage/providers.dart';
import 'core/storage/expiry_sweeper.dart';
import 'core/network/push_handler.dart';
import 'presentation/state/app_providers.dart';
import 'presentation/state/security_providers.dart';




const MethodChannel _wantedWipeChannel =
    MethodChannel('ecc.stellar.app/wanted_mode_monitor');

Future<bool> _hasPendingNativeWipe() async {
  if (!Platform.isAndroid) return false;
  try {
    return await _wantedWipeChannel.invokeMethod<bool>(
          'hasPendingLocalWipe',
        ) ??
        false;
  } on MissingPluginException {
    return false;
  }
}

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
  final wipePendingAtStartup = await _hasPendingNativeWipe();

  if (wipePendingAtStartup) {
    await _wipeLocalFilesAndKeys();
    await _wantedWipeChannel.invokeMethod<bool>('completeLocalWipe');
    return;
  }

  // Clear any decrypted Story video left by a previous force-stop or crash.
  try {
    await cleanupStoryTemporaryFiles();
  } on FileSystemException catch (error, stackTrace) {
    developer.log(
      'Could not remove a leftover Story video during startup.',
      name: 'stellar_ecc.stories',
      error: error,
      stackTrace: stackTrace,
    );
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
  final sweeper = ExpirySweeper(
    database,
    mediaService: MediaAttachmentService(
      db: database,
      keyStore: PlatformKeyStore(),
    ),
  );
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
  final wipePendingAfterOpen = await _hasPendingNativeWipe();
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
      // A removed account must never be silently registered again. Only the
      // signed response for this exact Signal identity can authorize a wipe.
      final revoked = await container
          .read(guardCaseServiceProvider)
          .isAccountRevoked(nickname)
          .timeout(const Duration(seconds: 12));
      if (revoked) {
        // Persist a native wipe marker *before* removing keys or files.
        // Interrupted cleanup is retried on next launch, then the native
        // Activity restart returns to the welcome screen.
        bool? armed;
        if (Platform.isAndroid) {
          try {
            armed = await _wantedWipeChannel.invokeMethod<bool>(
              'requestVerifiedGuardWipe',
            );
          } on MissingPluginException {
            // The local cleanup fallback handles platforms without a marker.
          }
        }
        if (armed == true) {
          await performWantedModeLocalWipe();
          return;
        }
        if (armed == false) {
          throw StateError('Guard wipe marker not persisted');
        }
        if (armed == null) {
          await container.read(wantedModeControllerProvider).wipeAndLock();
        }
      } else {
      final wipePendingBeforeDirectorySync =
          await _hasPendingNativeWipe();

      if (!wipePendingBeforeDirectorySync) {
        final sessionManager = container.read(sessionManagerProvider);
        final directoryClient = container.read(directoryClientProvider);

        await sessionManager.ensureMinimumPreKeys();

        final wipePendingAfterPreKeys = await _hasPendingNativeWipe();

        if (!wipePendingAfterPreKeys) {
          final bundle = await sessionManager.buildLocalDirectoryBundle();

          final wipePendingBeforeUpdate = await _hasPendingNativeWipe();

          if (!wipePendingBeforeUpdate) {
            try {
              await directoryClient.updateBundle(
                nickname: nickname,
                preKeyBundle: bundle,
              );
            } catch (e) {
              final text = e.toString();
              // No startup auto-registration. The onboarding flow alone may
              // create a new account after identity verification.
              developer.log('Directory bundle update skipped: $text',
                  name: 'stellar_ecc.directory');
            }

            developer.log(
              'Startup Signal bundle synchronization completed.',
              name: 'stellar_ecc.directory',
            );
          }
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

  final wipePendingBeforePush = await _hasPendingNativeWipe();
  if (wipePendingBeforePush) {
    await performWantedModeLocalWipe();
    return;
  }

  // Request Android runtime permissions once, after all wipe guards.
  if (Platform.isAndroid) {
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
  if (Platform.isAndroid) {
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
