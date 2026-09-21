import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_core/firebase_core.dart';

import 'app/app.dart';
import 'app/firebase_options.dart';
import 'core/storage/database.dart';
import 'core/storage/providers.dart';
import 'core/storage/expiry_sweeper.dart';
import 'core/network/push_handler.dart';
import 'core/network/relay_client.dart';
import 'core/network/envelope.dart';
import 'data/repositories/chat_repository.dart';
import 'presentation/state/app_providers.dart';

import 'package:firebase_messaging/firebase_messaging.dart';


@pragma('vm:entry-point')
Future<void> stellarPushBackgroundMain() async {
  WidgetsFlutterBinding.ensureInitialized();

  const backgroundChannel =
      MethodChannel('ecc.stellar.app/push_background');

  StellarDatabase? database;
  ProviderContainer? container;
  RelayClient? relayClient;

  Timer? idleTimer;
  Timer? hardTimeout;

  var completed = false;

  Future<void> complete() async {
    if (completed) {
      return;
    }

    completed = true;

    idleTimer?.cancel();
    hardTimeout?.cancel();

    try {
      await relayClient?.disconnect();
    } catch (_) {}

    try {
      container?.dispose();
    } catch (_) {}

    try {
      database?.close();
    } catch (_) {}

    try {
      await backgroundChannel.invokeMethod(
        'backgroundComplete',
      );
    } catch (error, stackTrace) {
      developer.log(
        'FIX5-B backgroundComplete failed.',
        name: 'stellar_ecc.push.background',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  try {
    // ----------------------------------------------------------
    // Firebase must be initialized again in the headless isolate.
    // ----------------------------------------------------------
    try {
      await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform,
      );
    } catch (error) {
      // Firebase may already be initialized inside this isolate.
      developer.log(
        'FIX5-B Firebase initialization note.',
        name: 'stellar_ecc.push.background',
        error: error,
      );
    }

    // ----------------------------------------------------------
    // Open the SAME SQLCipher database used by the application.
    // ----------------------------------------------------------
    database = await StellarDatabase.open();

    // ----------------------------------------------------------
    // Create an isolated ProviderContainer using the same DB.
    // ----------------------------------------------------------
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database!),
      ],
    );

    final keyStore =
        container!.read(platformKeyStoreProvider);

    final nicknameBytes =
        await keyStore.readSecret(
      'stellar.local_nickname',
    );

    final nickname = nicknameBytes == null
        ? null
        : String.fromCharCodes(
            nicknameBytes,
          ).trim().toLowerCase();

    if (nickname == null || nickname.isEmpty) {
      developer.log(
        'FIX5-B no local nickname; ending background sync.',
        name: 'stellar_ecc.push.background',
      );

      await complete();
      return;
    }

    // ----------------------------------------------------------
    // Use the EXISTING RelayClient.
    // This automatically performs the Signal identity relay auth.
    // ----------------------------------------------------------
    relayClient =
        container!.read(relayClientProvider);

    final chatRepository =
        container!.read(chatRepositoryProvider);

    var processingQueue = Future<void>.value();

    var receivedAny = false;

    late final StreamSubscription<RelayDelivery> subscription;

    subscription =
        relayClient!.incomingDelivery.listen(
      (delivery) {
        final bytes = delivery.bytes;
        final deliveryId = delivery.deliveryId;
        receivedAny = true;

        processingQueue = processingQueue.then(
          (_) async {
            try {
              developer.log(
                'FIX5-D encrypted envelope received: '
                '${bytes.length} bytes',
                name: 'stellar_ecc.push.background',
              );

              // The envelope delivery token is the persistent application
              // dedupe key. Relay delivery IDs are transport-local and must
              // not be used for decrypt deduplication.
              final envelope =
                  Envelope.decode(bytes);

              final alreadyProcessed =
                  await database!.messageDao
                      .isProcessedEnvelope(
                    envelope.deliveryToken,
                  );

              if (alreadyProcessed) {
                developer.log(
                  'FIX5-D envelope already processed; '
                  'skipping Signal decrypt.',
                  name: 'stellar_ecc.push.background',
                );

                if (deliveryId != null) {
                  await relayClient!.acknowledgeDelivery(
                    deliveryId,
                  );
                }

                return;
              }

              // IMPORTANT:
              // Reuse the SAME Signal decryption path as foreground.
              final decrypted =
                  await chatRepository.decryptEnvelope(
                rawEnvelope: bytes,
              );

              final plaintext = utf8.decode(
                decrypted.plaintextBytes,
                allowMalformed: false,
              );

              const callPrefix =
                  'STELLAR_CALL_V1:';

              if (plaintext.startsWith(callPrefix)) {
                // Call wake-up itself is handled by the native
                // FirebaseMessagingService / Telecom path.
                //
                // Do not route UI/call navigation from the headless
                // isolate. The envelope was successfully decrypted, so
                // persist the dedupe marker before acknowledging Relay.
                developer.log(
                  'FIX5-D call envelope received in background; '
                  'UI routing skipped.',
                  name: 'stellar_ecc.push.background',
                );

                await database!.messageDao
                    .markEnvelopeProcessed(
                  envelope.deliveryToken,
                );
              } else {
                await chatRepository
                    .receiveDecryptedEnvelope(
                  decrypted: decrypted,
                );

                developer.log(
                  'FIX5-D envelope application processing completed.',
                  name: 'stellar_ecc.push.background',
                );

                await database!.messageDao
                    .markEnvelopeProcessed(
                  envelope.deliveryToken,
                );
              }

              if (deliveryId != null) {
                await relayClient!.acknowledgeDelivery(
                  deliveryId,
                );
              }
            } catch (error, stackTrace) {
              // No processed marker and no Relay ACK are written when
              // decrypt/application processing fails. The queued envelope
              // therefore remains retryable.
              developer.log(
                'FIX5-D envelope processing failed; '
                'leaving delivery queued for retry.',
                name: 'stellar_ecc.push.background',
                error: error,
                stackTrace: stackTrace,
              );
            }
          },
        );

        // Give the relay a short idle period after the last
        // received envelope. The Future chain above guarantees that
        // envelopes are processed strictly one at a time.
        idleTimer?.cancel();

        idleTimer = Timer(
          const Duration(seconds: 3),
          () async {
            try {
              await processingQueue;
            } finally {
              await subscription.cancel();
              await complete();
            }
          },
        );
      },
    );

    // ----------------------------------------------------------
    // Connect to the authenticated relay.
    // ----------------------------------------------------------
    await relayClient!.connect(
      peer: nickname,
    );

    developer.log(
      'FIX5-B authenticated relay connection established.',
      name: 'stellar_ecc.push.background',
    );

    // ----------------------------------------------------------
    // If there are no queued messages, finish after a short
    // bounded idle period.
    // ----------------------------------------------------------
    idleTimer = Timer(
      const Duration(seconds: 3),
      () async {
        if (!receivedAny) {
          try {
            await subscription.cancel();
          } finally {
            await complete();
          }
        }
      },
    );

    // ----------------------------------------------------------
    // Absolute safety timeout.
    // Never leave the headless isolate running indefinitely.
    // ----------------------------------------------------------
    hardTimeout = Timer(
      const Duration(seconds: 15),
      () async {
        try {
          await processingQueue;
        } finally {
          await subscription.cancel();
          await complete();
        }
      },
    );
  } catch (error, stackTrace) {
    developer.log(
      'FIX5-B background message sync failed.',
      name: 'stellar_ecc.push.background',
      error: error,
      stackTrace: stackTrace,
    );

    await complete();
  }
}

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
