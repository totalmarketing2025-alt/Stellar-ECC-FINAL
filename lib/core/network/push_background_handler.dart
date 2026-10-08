import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/firebase_options.dart';
import 'envelope.dart';
import 'relay_client.dart';
import 'push_handler.dart';
import '../storage/database.dart';
import '../storage/providers.dart';
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

  // FIX4:
  // Keep token-registration failure separate so the native
  // WorkManager job can retry when FCM registration fails.
  var tokenRegistrationFailed = false;

  Timer? idleTimer;
  Timer? hardTimeout;

  var completed = false;

  Future<void> showLocalMessageNotification() async {
    try {
      await backgroundChannel.invokeMethod(
        'showMessageNotification',
      );
    } catch (error, stackTrace) {
      developer.log(
        'Local message notification failed.',
        name: 'stellar_ecc.push.background',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> complete({
    bool success = true,
  }) async {
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
        success,
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
    final db = await StellarDatabase.open();
    database = db;

    // ----------------------------------------------------------
    // Create an isolated ProviderContainer using the same DB.
    // ----------------------------------------------------------
    final providerContainer = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
      ],
    );
    container = providerContainer;

    final keyStore =
        providerContainer.read(platformKeyStoreProvider);

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
    final client =
        providerContainer.read(relayClientProvider);
    relayClient = client;

    final chatRepository =
        providerContainer.read(chatRepositoryProvider);

    // ----------------------------------------------------------
    // FIX4:
    // FCM may rotate its token while the Flutter application is
    // not running. Register the current token through the same
    // challenge + Signal identity signature path used by the
    // foreground PushHandler.
    //
    // This is deliberately done before relay synchronization so
    // a newly issued FCM token is persisted in Directory even when
    // the token-refresh callback arrived while the app was closed.
    // ----------------------------------------------------------
    try {
      final pushHandler = PushHandler(
        relayClient: client,
        messaging: FirebaseMessaging.instance,
        directoryClient: container.read(
          directoryClientProvider,
        ),
        sessionManager: container.read(
          sessionManagerProvider,
        ),
        getLocalNickname: () async => nickname,
      );

      await pushHandler.registerCurrentToken();

      developer.log(
        'FIX4 FCM token registration completed.',
        name: 'stellar_ecc.push.background',
      );
    } catch (error, stackTrace) {
      tokenRegistrationFailed = true;

      developer.log(
        'FIX4 FCM token registration failed; '
        'background job will request a retry.',
        name: 'stellar_ecc.push.background',
        error: error,
        stackTrace: stackTrace,
      );
    }

    var processingQueue = Future<void>.value();

    var receivedAny = false;
    var processingFailed = false;

    late final StreamSubscription<RelayDelivery> subscription;

    subscription =
        client.incomingDelivery.listen(
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
                  await db.messageDao
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
                  await client.acknowledgeDelivery(
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

              await chatRepository
                  .receiveDecryptedEnvelope(
                decrypted: decrypted,
              );

              // Call signaling is transport-only and is handled by the
              // native FirebaseMessagingService / Telecom path.
              // A Signal-decrypted envelope is always a normal chat
              // message and must never be interpreted as a call signal.
              await showLocalMessageNotification();

              developer.log(
                'Background envelope application processing completed.',
                name: 'stellar_ecc.push.background',
              );

              await db.messageDao
                  .markEnvelopeProcessed(
                envelope.deliveryToken,
              );

              if (deliveryId != null) {
                await client.acknowledgeDelivery(
                  deliveryId,
                );
              }
            } catch (error, stackTrace) {
              // No processed marker and no Relay ACK are written when
              // decrypt/application processing fails. The queued envelope
              // therefore remains retryable.
              processingFailed = true;

              developer.log(
                'FIX10 envelope processing failed; '
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
              await complete(
                success: !processingFailed &&
                    !tokenRegistrationFailed,
              );
            }
          },
        );
      },
    );

    // ----------------------------------------------------------
    // Connect to the authenticated relay.
    // ----------------------------------------------------------
    await relayClient.connect(
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
            await complete(
              success: !tokenRegistrationFailed,
            );
          }
        }
      },
    );

    // ----------------------------------------------------------
    // Absolute safety timeout.
    // Never leave the headless isolate running indefinitely.
    // ----------------------------------------------------------
    hardTimeout = Timer(
      const Duration(seconds: 45),
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

    await complete(
      success: false,
    );
  }
}
