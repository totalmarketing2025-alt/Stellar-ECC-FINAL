import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'package:stellar_ecc/core/network/envelope.dart';

const relayUrl =
    'wss://stellar-ecc-final.totalmarketing2025.workers.dev/v1/connect';

Future<WebSocketChannel> connect(String username) async {
  final uri = Uri.parse(relayUrl).replace(
    queryParameters: {'peer': username},
  );

  final channel = WebSocketChannel.connect(uri);
  await channel.ready;
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

Future<Uint8List> receive(WebSocketChannel channel) {
  return channel.stream
      .map<Uint8List>((data) => data is List<int>
          ? Uint8List.fromList(data)
          : Uint8List.fromList((data as String).codeUnits))
      .first
      .timeout(const Duration(seconds: 8));
}

void main() {
  test(
    'Stellar real chat: Alice <-> Bob through Cloudflare Relay',
    () async {
      final alice = await connect('alice');
      final bob = await connect('bob');

      try {
        print('CHAT 1: CREATE ALICE');
        final aliceIdentity = generateIdentityKeyPair();
        final aliceStore = InMemorySignalProtocolStore(
          aliceIdentity,
          generateRegistrationId(false),
        );

        print('CHAT 2: CREATE BOB');
        final bobIdentity = generateIdentityKeyPair();
        final bobRegistrationId = generateRegistrationId(false);
        final bobStore = InMemorySignalProtocolStore(
          bobIdentity,
          bobRegistrationId,
        );

        final bobPreKeys = generatePreKeys(0, 10);
        for (final key in bobPreKeys) {
          await bobStore.storePreKey(key.id, key);
        }

        final bobSignedPreKey =
            generateSignedPreKey(bobIdentity, 0);

        await bobStore.storeSignedPreKey(
          bobSignedPreKey.id,
          bobSignedPreKey,
        );

        final bobBundle = PreKeyBundle(
          bobRegistrationId,
          1,
          bobPreKeys.first.id,
          bobPreKeys.first.getKeyPair().publicKey,
          bobSignedPreKey.id,
          bobSignedPreKey.getKeyPair().publicKey,
          bobSignedPreKey.signature,
          bobIdentity.getPublicKey(),
        );

        const aliceAddress =
            SignalProtocolAddress('alice', 1);
        const bobAddress =
            SignalProtocolAddress('bob', 1);

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
            recipient: 'bob',
            ciphertext:
                Uint8List.fromList(aliceCiphertext.serialize()),
          ).encode(),
        );

        final bobEnvelope =
            Envelope.decode(await bobFuture);

        expect(bobEnvelope.recipientRoute, 'bob');

        final PreKeySignalMessage bobSignal =
            PreKeySignalMessage(bobEnvelope.ciphertext);

        Uint8List? bobPlaintext;
        await bobCipher.decryptWithCallback(
          bobSignal,
          (plaintext) {
            bobPlaintext = plaintext;
          },
        );
        expect(utf8.decode(bobPlaintext!), aliceText);

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
            recipient: 'alice',
            ciphertext:
                Uint8List.fromList(bobCiphertext.serialize()),
          ).encode(),
        );

        final aliceEnvelope =
            Envelope.decode(await aliceFuture);

        expect(aliceEnvelope.recipientRoute, 'alice');

        final alicePlaintext =
            await aliceCipher.decryptFromSignal(
          SignalMessage.fromSerialized(
            aliceEnvelope.ciphertext,
          ),
        );
        expect(utf8.decode(alicePlaintext), bobText);

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
            recipient: 'bob',
            ciphertext:
                Uint8List.fromList(secondCiphertext.serialize()),
          ).encode(),
        );

        final secondEnvelope =
            Envelope.decode(await secondBobFuture);

        final secondPlaintext =
            await bobCipher.decryptFromSignal(
          SignalMessage.fromSerialized(
            secondEnvelope.ciphertext,
          ),
        );
        expect(utf8.decode(secondPlaintext), secondText);

        print('CHAT RESULT: ALICE <-> BOB SUCCESS');
      } finally {
        await alice.sink.close();
        await bob.sink.close();
      }
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
