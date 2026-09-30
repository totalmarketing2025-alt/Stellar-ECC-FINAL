import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/firebase_options.dart';
import 'envelope.dart';
import 'relay_client.dart';
import '../../data/repositories/chat_repository.dart';
import '../storage/database.dart';
import '../storage/providers.dart';
import '../security/platform_key_store.dart';
import '../../presentation/state/app_providers.dart';

@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(
  RemoteMessage message,
) async {
  await stellarPushBackgroundMain();
}

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
      () {
        // Native StellarPushBackgroundRunner owns the real hard cutoff.
        // Never await processingQueue here: a stuck queue must not block
        // the 15s safety path.
        unawaited(subscription.cancel());
        unawaited(relayClient?.disconnect());
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
