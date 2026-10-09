import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'package:stellar_ecc/core/network/envelope.dart';

const relayUrl =
    'wss://stellar-ecc-final.totalmarketing2025.workers.dev/v1/connect';

const directoryUrl =
    'https://stellar-ecc-directory.totalmarketing2025.workers.dev';

const relayAuthChallengePrefix =
    'STELLAR_RELAY_AUTH_CHALLENGE_V1:';

const relayAuthResponsePrefix =
    'STELLAR_RELAY_AUTH_RESPONSE_V1:';

const relayAuthOk =
    'STELLAR_RELAY_AUTH_OK_V1';

class TestIdentity {
  TestIdentity({
    required this.nickname,
    required this.identity,
    required this.registrationId,
    required this.store,
    required this.bundle,
    required this.preKey,
    required this.signedPreKey,
  });

  final String nickname;
  final IdentityKeyPair identity;
  final int registrationId;
  final InMemorySignalProtocolStore store;
  final PreKeyBundle bundle;
  final PreKeyRecord preKey;
  final SignedPreKeyRecord signedPreKey;
}

Future<TestIdentity> createTestIdentity(
  String nickname, {
  int deviceId = 1,
}) async {
  final identity = generateIdentityKeyPair();
  final registrationId = generateRegistrationId(false);

  final store = InMemorySignalProtocolStore(
    identity,
    registrationId,
  );

  final preKeys = generatePreKeys(0, 1);

  for (final preKey in preKeys) {
    await store.storePreKey(preKey.id, preKey);
  }

  final signedPreKey = generateSignedPreKey(identity, 0);

  await store.storeSignedPreKey(
    signedPreKey.id,
    signedPreKey,
  );

  final bundle = PreKeyBundle(
    registrationId,
    deviceId,
    preKeys.first.id,
    preKeys.first.getKeyPair().publicKey,
    signedPreKey.id,
    signedPreKey.getKeyPair().publicKey,
    signedPreKey.signature,
    identity.getPublicKey(),
  );

  return TestIdentity(
    nickname: nickname,
    identity: identity,
    registrationId: registrationId,
    store: store,
    bundle: bundle,
    preKey: preKeys.first,
    signedPreKey: signedPreKey,
  );
}

Map<String, dynamic> directoryBundleJson(
  TestIdentity user, {
  int deviceId = 1,
}) {
  return {
    'registrationId': user.registrationId,
    'deviceId': deviceId,
    'identityKey': base64Encode(
      user.identity.getPublicKey().serialize(),
    ),
    'signedPreKey': {
      'keyId': user.signedPreKey.id,
      'publicKey': base64Encode(
        user.signedPreKey.getKeyPair().publicKey.serialize(),
      ),
      'signature': base64Encode(
        user.signedPreKey.signature,
      ),
    },
    'preKey': {
      'keyId': user.preKey.id,
      'publicKey': base64Encode(
        user.preKey.getKeyPair().publicKey.serialize(),
      ),
    },
  };
}

Future<void> registerInDirectory(
  TestIdentity user,
) async {
  final client = HttpClient();

  try {
    final request = await client.postUrl(
      Uri.parse('$directoryUrl/v1/register'),
    );

    request.headers.contentType = ContentType.json;

    request.write(
      jsonEncode({
        'nickname': user.nickname,
        'bundle': directoryBundleJson(user),
      }),
    );

    final response = await request.close();
    final body = await utf8.decoder.bind(response).join();

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError(
        'Directory registration failed for '
        '${user.nickname}: HTTP ${response.statusCode} $body',
      );
    }
  } finally {
    client.close(force: true);
  }
}

Future<WebSocketChannel> connectAuthenticated(
  TestIdentity user,
) async {
  final uri = Uri.parse(relayUrl).replace(
    queryParameters: {'peer': user.nickname},
  );

  final channel = WebSocketChannel.connect(uri);
  await channel.ready;

  final broadcastStream = channel.stream.asBroadcastStream();
  _broadcastStreams[channel] = broadcastStream;

  final authCompleter = Completer<void>();

  late StreamSubscription<dynamic> subscription;

  subscription = broadcastStream.listen(
    (data) {
      if (data is! String) {
        return;
      }

      if (data.startsWith(relayAuthChallengePrefix)) {
        final challenge =
            data.substring(relayAuthChallengePrefix.length);

        final message = jsonEncode([
          'stellar-relay-v1',
          user.nickname,
          1,
          user.registrationId,
          challenge,
        ]);

        final signature = Curve.calculateSignature(
          user.identity.getPrivateKey(),
          Uint8List.fromList(
            utf8.encode(message),
          ),
        );

        channel.sink.add(
          '$relayAuthResponsePrefix'
          '${jsonEncode({
            'challenge': challenge,
            'deviceId': 1,
            'registrationId': user.registrationId,
            'signature': base64Encode(signature),
          })}',
        );

        return;
      }

      if (data == relayAuthOk) {
        if (!authCompleter.isCompleted) {
          authCompleter.complete();
        }
      }
    },
    onError: (Object error, StackTrace stack) {
      if (!authCompleter.isCompleted) {
        authCompleter.completeError(error, stack);
      }
    },
    onDone: () {
      if (!authCompleter.isCompleted) {
        authCompleter.completeError(
          StateError(
            'Relay closed before authentication for '
            '${user.nickname}',
          ),
        );
      }
    },
  );

  try {
    await authCompleter.future.timeout(
      const Duration(seconds: 10),
    );
  } catch (_) {
    await subscription.cancel();
    _broadcastStreams.remove(channel);
    await channel.sink.close();
    rethrow;
  }

  await subscription.cancel();
  return channel;
}

Envelope makeEnvelope({
  required String recipient,
  required Uint8List ciphertext,
}) {
  return Envelope(
    deliveryToken: Uint8List.fromList(utf8.encode('test-token-1234')),
    recipientRoute: recipient,
    ciphertext: ciphertext,
  );
}

final _streamControllers =
    <WebSocketChannel, StreamController<Uint8List>>{};

final _broadcastStreams =
    <WebSocketChannel, Stream<dynamic>>{};

StreamController<Uint8List> _controllerFor(
  WebSocketChannel channel,
) {
  return _streamControllers.putIfAbsent(
    channel,
    () {
      final controller = StreamController<Uint8List>.broadcast();

      final stream = _broadcastStreams[channel];

      if (stream == null) {
        throw StateError(
          'Relay broadcast stream was not initialized',
        );
      }

      stream.listen(
        (data) {
          if (data is List<int>) {
            controller.add(Uint8List.fromList(data));
            return;
          }

          // Relay control frames are intentionally ignored here.
          // They must never enter Envelope.decode().
        },
        onError: controller.addError,
        onDone: controller.close,
      );

      return controller;
    },
  );
}

Future<Uint8List> receive(WebSocketChannel channel) {
  return _controllerFor(channel)
      .stream
      .first
      .timeout(const Duration(seconds: 8));
}

void main() {
  test(
    'Stellar real chat: Alice <-> Bob through Cloudflare Relay',
    () async {
      final runId =
          DateTime.now().microsecondsSinceEpoch.toString();
      final aliceNickname = 'alice$runId';
      final bobNickname = 'bob$runId';

      print('CHAT 1: CREATE ALICE');
      final aliceUser = await createTestIdentity(aliceNickname);
      await registerInDirectory(aliceUser);

      print('CHAT 2: CREATE BOB');
      final bobUser = await createTestIdentity(bobNickname);
      await registerInDirectory(bobUser);

      final alice = await connectAuthenticated(aliceUser);
      final bob = await connectAuthenticated(bobUser);

      try {
        final aliceStore = aliceUser.store;

        final bobStore = bobUser.store;

        final bobBundle = bobUser.bundle;

        final aliceAddress =
            SignalProtocolAddress(aliceNickname, 1);
        final bobAddress =
            SignalProtocolAddress(bobNickname, 1);

        print('CHAT 3: X3DH');

        final builder = SessionBuilder(
          aliceStore.sessionStore,
          aliceStore.preKeyStore,
          aliceStore.signedPreKeyStore,
          aliceStore,
          bobAddress,
        );

        await builder.processPreKeyBundle(bobBundle);

        expect(
          await aliceStore.containsSession(bobAddress),
          isTrue,
        );

        final aliceCipher =
            SessionCipher.fromStore(aliceStore, bobAddress);

        final bobCipher =
            SessionCipher.fromStore(bobStore, aliceAddress);

        print('CHAT 4: ALICE -> BOB');

        const aliceText = 'Hello Bob!';

        final aliceCiphertext = await aliceCipher.encrypt(
          Uint8List.fromList(utf8.encode(aliceText)),
        );

        final bobFuture = receive(bob);

        alice.sink.add(
          makeEnvelope(
            recipient: bobNickname,
            ciphertext:
                Uint8List.fromList(aliceCiphertext.serialize()),
          ).encode(),
        );

        final bobEnvelope =
            Envelope.decode(await bobFuture);

        expect(bobEnvelope.recipientRoute, bobNickname);

        final receivedCiphertext = bobEnvelope.ciphertext;
        expect(
          receivedCiphertext,
          orderedEquals(aliceCiphertext.serialize()),
          reason: 'Relay/Envelope modified the Signal ciphertext',
        );

        final PreKeySignalMessage bobSignal =
            PreKeySignalMessage(receivedCiphertext);

        Uint8List? bobPlaintext;
        print('CHAT STEP: BOB DECRYPT START');
        await bobCipher.decryptWithCallback(
          bobSignal,
          (plaintext) {
            bobPlaintext = plaintext;
          },
        );
        expect(bobPlaintext, isNotNull, reason: 'CHAT STEP FAILED: Bob decrypt returned null');
        expect(utf8.decode(bobPlaintext!), aliceText, reason: 'CHAT STEP FAILED: Bob plaintext mismatch');

        print('CHAT 5: BOB -> ALICE');

        const bobText = 'Hello Alice!';

        final bobCiphertext = await bobCipher.encrypt(
          Uint8List.fromList(utf8.encode(bobText)),
        );

        expect(
          bobCiphertext.getType(),
          CiphertextMessage.whisperType,
        );

        final aliceFuture = receive(alice);

        bob.sink.add(
          makeEnvelope(
            recipient: aliceNickname,
            ciphertext:
                Uint8List.fromList(bobCiphertext.serialize()),
          ).encode(),
        );

        final aliceEnvelope =
            Envelope.decode(await aliceFuture);

        expect(aliceEnvelope.recipientRoute, aliceNickname);

        print('CHAT STEP: ALICE DECRYPT REPLY START');
        final alicePlaintext =
            await aliceCipher.decryptFromSignal(
          SignalMessage.fromSerialized(
            aliceEnvelope.ciphertext,
          ),
        );
        expect(utf8.decode(alicePlaintext), bobText, reason: 'CHAT STEP FAILED: Alice plaintext mismatch');

        print('CHAT 6: ALICE -> BOB AGAIN');

        const secondText = 'How are you?';

        final secondCiphertext = await aliceCipher.encrypt(
          Uint8List.fromList(utf8.encode(secondText)),
        );

        expect(
          secondCiphertext.getType(),
          CiphertextMessage.whisperType,
        );

        final secondBobFuture = receive(bob);

        alice.sink.add(
          makeEnvelope(
            recipient: bobNickname,
            ciphertext:
                Uint8List.fromList(secondCiphertext.serialize()),
          ).encode(),
        );

        final secondEnvelope =
            Envelope.decode(await secondBobFuture);

        print('CHAT STEP: BOB DECRYPT SECOND START');
        final secondPlaintext =
            await bobCipher.decryptFromSignal(
          SignalMessage.fromSerialized(
            secondEnvelope.ciphertext,
          ),
        );
        expect(utf8.decode(secondPlaintext), secondText);

        print('CHAT RESULT: ALICE <-> BOB SUCCESS');
      } catch (error, stack) {
        print('CHAT ERROR: $error');
        print('CHAT STACK TRACE:');
        print(stack);
        rethrow;
      } finally {
        await alice.sink.close();
        await bob.sink.close();
        _broadcastStreams.remove(alice);
        _broadcastStreams.remove(bob);
      }
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
