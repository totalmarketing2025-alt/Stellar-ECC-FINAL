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

Future<void> _cleanupStoryFiles() async {
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
}

Future<bool> _initializeFirebase() async {
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    return true;
  } catch (error, stackTrace) {
    // Missing/placeholder Firebase configuration must not block local use.
    developer.log(
      'Firebase init failed — continuing without push notifications. '
      'Run `flutterfire configure` against a real project to enable this.',
      name: 'stellar_ecc.startup',
      error: error,
      stackTrace: stackTrace,
    );
    return false;
  }
}

Future<void> _synchronizeSignalBundleInBackground(
  ProviderContainer container,
  String nickname,
) async {
  try {
    if (await _hasPendingNativeWipe()) return;

    final sessionManager = container.read(sessionManagerProvider);
    final directoryClient = container.read(directoryClientProvider);
    await sessionManager.ensureMinimumPreKeys();

    if (await _hasPendingNativeWipe()) return;

    final bundle = await sessionManager.buildLocalDirectoryBundle();
    if (await _hasPendingNativeWipe()) return;

    try {
      await directoryClient.updateBundle(
        nickname: nickname,
        preKeyBundle: bundle,
      );
    } catch (error) {
      // No startup auto-registration. The onboarding flow alone may create a
      // new account after identity verification.
      developer.log(
        'Directory bundle update skipped: $error',
        name: 'stellar_ecc.directory',
      );
      return;
    }

    developer.log(
      'Background Signal bundle synchronization completed.',
      name: 'stellar_ecc.directory',
    );
  } catch (error, stackTrace) {
    developer.log(
      'Background Signal bundle synchronization failed.',
      name: 'stellar_ecc.directory',
      error: error,
      stackTrace: stackTrace,
    );
  }
}

Future<void> _initializeOptionalStartupServices(
  ProviderContainer container,
  bool firebaseAvailable,
) async {
  try {
    if (await _hasPendingNativeWipe()) return;

    if (firebaseAvailable) {
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
      } catch (error, stackTrace) {
        developer.log(
          'Push handler init failed — continuing without push notifications.',
          name: 'stellar_ecc.startup',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }

    if (Platform.isAndroid && !await _hasPendingNativeWipe()) {
      try {
        await _wantedWipeChannel.invokeMethod('requestStartupPermissions');
      } catch (error, stackTrace) {
        developer.log(
          'Startup permission request failed; continuing without blocking app.',
          name: 'stellar_ecc.startup',
          error: error,
          stackTrace: stackTrace,
        );
      }

      try {
        await _wantedWipeChannel.invokeMethod('requestFullScreenCallAccess');
      } catch (error, stackTrace) {
        developer.log(
          'Full-screen call access request failed; continuing.',
          name: 'stellar_ecc.startup',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }
  } catch (error, stackTrace) {
    developer.log(
      'Optional startup services failed; app remains available.',
      name: 'stellar_ecc.startup',
      error: error,
      stackTrace: stackTrace,
    );
  }
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

  // These startup tasks are independent. Start them together so Firebase
  // setup and stale temporary-file cleanup do not add their durations to the
  // encrypted database open time.
  final cleanupStoriesFuture = _cleanupStoryFiles();
  final firebaseFuture = _initializeFirebase();
  final databaseFuture = StellarDatabase.open();
  final database = await databaseFuture;
  final firebaseAvailable = await firebaseFuture;
  await cleanupStoriesFuture;

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
        // Prekey replenishment and Directory I/O are not needed to show the
        // local unlock screen. Run them after launch instead of delaying it.
        unawaited(_synchronizeSignalBundleInBackground(container, nickname));
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

  if (firebaseAvailable) {
    FirebaseMessaging.onBackgroundMessage(
      firebaseMessagingBackgroundHandler,
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

  // Token setup and system dialogs are useful, but neither should delay the
  // first rendered screen on Android or Windows.
  WidgetsBinding.instance.addPostFrameCallback((_) {
    unawaited(_initializeOptionalStartupServices(container, firebaseAvailable));
  });
}
