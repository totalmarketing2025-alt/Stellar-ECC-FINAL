import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

import 'package:stellar_ecc/core/network/envelope.dart';
import 'package:stellar_ecc/core/crypto/directory_signal_adapter.dart';
import 'package:stellar_ecc/core/network/directory_user_bundle.dart';

void main() {
  test(
    'Stellar Signal E2E: second message before recipient reply',
    () async {
      try {
      // ------------------------------------------------------------
      print('SIGNAL PHASE 1: ALICE');
// ALICE
      // ------------------------------------------------------------

      final aliceIdentity = generateIdentityKeyPair();
      final aliceRegistrationId = generateRegistrationId(false);

      final aliceStore = InMemorySignalProtocolStore(
        aliceIdentity,
        aliceRegistrationId,
      );

      final aliceAddress =
          const SignalProtocolAddress('alice', 1);

      final bobAddress =
          const SignalProtocolAddress('bob', 1);

      // ------------------------------------------------------------
      print('SIGNAL PHASE 2: BOB');
// BOB
      // ------------------------------------------------------------

      final bobIdentity = generateIdentityKeyPair();
      final bobRegistrationId = generateRegistrationId(false);

      final bobStore = InMemorySignalProtocolStore(
        bobIdentity,
        bobRegistrationId,
      );

      final bobPreKeys = generatePreKeys(0, 110);

      for (final preKey in bobPreKeys) {
        await bobStore.storePreKey(
          preKey.id,
          preKey,
        );
      }

      final bobSignedPreKey =
          generateSignedPreKey(bobIdentity, 0);

      await bobStore.storeSignedPreKey(
        bobSignedPreKey.id,
        bobSignedPreKey,
      );

      // ------------------------------------------------------------
      print('SIGNAL PHASE 3: DIRECTORY BUNDLE');
// DIRECTORY BUNDLE
      // Simulates exactly what Directory returns to Alice.
      // ------------------------------------------------------------

      final directoryBundle = DirectoryUserBundle(
        nickname: 'bob',
        registrationId: bobRegistrationId,
        deviceId: 1,
        identityKey: base64Encode(
          bobIdentity.getPublicKey().serialize(),
        ),
        signedPreKeyId: bobSignedPreKey.id,
        signedPreKey: base64Encode(
          bobSignedPreKey.getKeyPair().publicKey.serialize(),
        ),
        signedPreKeySignature: base64Encode(
          bobSignedPreKey.signature,
        ),
        preKeyId: bobPreKeys.first.id,
        preKey: base64Encode(
          bobPreKeys.first.getKeyPair().publicKey.serialize(),
        ),
      );

      // ------------------------------------------------------------
      print('SIGNAL PHASE 4: ADAPTER');
      // DIRECTORY -> LIBSIGNAL ADAPTER
      // ------------------------------------------------------------

      const adapter = DirectorySignalAdapter();

      final bobBundle =
          adapter.toPreKeyBundle(directoryBundle);

      expect(
        bobBundle.getRegistrationId(),
        bobRegistrationId,
      );

      expect(
        bobBundle.getDeviceId(),
        1,
      );

      // ------------------------------------------------------------
      print('SIGNAL PHASE 5: X3DH');
// X3DH SESSION ESTABLISHMENT
      // ------------------------------------------------------------

      final aliceSessionBuilder = SessionBuilder(
        aliceStore.sessionStore,
        aliceStore.preKeyStore,
        aliceStore.signedPreKeyStore,
        aliceStore,
        bobAddress,
      );

      await aliceSessionBuilder.processPreKeyBundle(
        bobBundle,
      );

      expect(
        await aliceStore.containsSession(bobAddress),
        isTrue,
      );

      // ------------------------------------------------------------
      print('SIGNAL PHASE 6: ENCRYPT');
// ALICE -> BOB ENCRYPTION
      // ------------------------------------------------------------

      const plaintext = 'Hello Bob — Stellar E2E works!';

      final aliceCipher =
          SessionCipher.fromStore(
        aliceStore,
        bobAddress,
      );

      final ciphertext = await aliceCipher.encrypt(
        Uint8List.fromList(
          utf8.encode(plaintext),
        ),
      );

      expect(
        ciphertext.serialize().isNotEmpty,
        isTrue,
      );

      // ------------------------------------------------------------
      // TRANSPORT SIMULATION
      // Serialize -> reconstruct exactly like network transport.
      // ------------------------------------------------------------

      final firstEnvelope = Envelope(
        envelopeVersion: 2,
        ciphertextType: ciphertext.getType(),
        deliveryToken: Uint8List.fromList([1, 2, 3, 4]),
        recipientRoute: 'bob',
        ciphertext: Uint8List.fromList(ciphertext.serialize()),
      );

      final firstDecoded = Envelope.decode(firstEnvelope.encode());

      expect(firstDecoded.envelopeVersion, 2);
      expect(firstDecoded.ciphertextType, CiphertextMessage.prekeyType);

      final received = PreKeySignalMessage(
        firstDecoded.ciphertext,
      );

      // ------------------------------------------------------------
      print('SIGNAL PHASE 7: BOB DECRYPT');
// BOB DECRYPTION
      // ------------------------------------------------------------

      final bobCipher =
          SessionCipher.fromStore(
        bobStore,
        aliceAddress,
      );

      Uint8List? decrypted;

      await bobCipher.decryptWithCallback(
        received,
        (plaintext) {
          decrypted = plaintext;
        },
      );

      if (decrypted == null) {
        throw StateError(
          'Bob did not produce decrypted plaintext',
        );
      }

      final result =
          utf8.decode(decrypted!);

      expect(result, plaintext);

      // ------------------------------------------------------------
      print('SIGNAL PHASE 8: DOUBLE RATCHET');
      // Regression: Alice sends again BEFORE Bob replies.
      // The second ciphertext can still be a PreKeySignalMessage.
      const earlySecondText = 'Second message before Bob replies';

      final earlySecondCiphertext = await aliceCipher.encrypt(
        Uint8List.fromList(utf8.encode(earlySecondText)),
      );

      expect(
        earlySecondCiphertext.getType(),
        CiphertextMessage.prekeyType,
      );

      final secondEnvelope = Envelope(
        envelopeVersion: 2,
        ciphertextType: earlySecondCiphertext.getType(),
        deliveryToken: Uint8List.fromList([5, 6, 7, 8]),
        recipientRoute: 'bob',
        ciphertext: Uint8List.fromList(
          earlySecondCiphertext.serialize(),
        ),
      );

      final secondDecoded = Envelope.decode(secondEnvelope.encode());

      expect(secondDecoded.envelopeVersion, 2);
      expect(secondDecoded.ciphertextType, CiphertextMessage.prekeyType);

      final earlySecondReceived = PreKeySignalMessage(
        secondDecoded.ciphertext,
      );

      final earlySecondPlaintext = await bobCipher.decrypt(
        earlySecondReceived,
      );

      expect(
        utf8.decode(earlySecondPlaintext),
        earlySecondText,
      );

      print('REGRESSION: SECOND MESSAGE DECRYPTED SUCCESSFULLY');

      // Bob now replies and acknowledges the PreKey session.


      const bobReply = 'Bob reply — session acknowledged!';

      final bobReplyCipher =
          SessionCipher.fromStore(
        bobStore,
        aliceAddress,
      );

      final bobReplyCiphertext = await bobReplyCipher.encrypt(
        Uint8List.fromList(
          utf8.encode(bobReply),
        ),
      );

      print(
        'SIGNAL PHASE 8A: BOB REPLY TYPE '
        '${bobReplyCiphertext.getType()} '
        '(expected ${CiphertextMessage.whisperType})',
      );

      expect(
        bobReplyCiphertext.getType(),
        CiphertextMessage.whisperType,
      );

      final transmittedBobReply =
          bobReplyCiphertext.serialize();

      final receivedBobReply =
          SignalMessage.fromSerialized(transmittedBobReply);

      final aliceReplyCipher =
          SessionCipher.fromStore(
        aliceStore,
        bobAddress,
      );

      final decryptedBobReply =
          await aliceReplyCipher.decryptFromSignal(
        receivedBobReply,
      );

      expect(
        utf8.decode(decryptedBobReply),
        bobReply,
      );

      print('SIGNAL PHASE 8B: ALICE RECEIVED BOB REPLY');

      // Alice can now continue the Double Ratchet with a normal
      // SignalMessage.

      const secondPlaintext =
          'Second message — Double Ratchet continues!';

      final secondCiphertext =
          await aliceCipher.encrypt(
        Uint8List.fromList(
          utf8.encode(secondPlaintext),
        ),
      );

      print(
        'SIGNAL PHASE 8C: SECOND CIPHERTEXT TYPE '
        '${secondCiphertext.getType()} '
        '(expected ${CiphertextMessage.whisperType})',
      );

      expect(
        secondCiphertext.getType(),
        CiphertextMessage.whisperType,
      );

      final transmittedSecond =
          secondCiphertext.serialize();

      final receivedSecond =
          SignalMessage.fromSerialized(
        transmittedSecond,
      );

      final decryptedSecond =
          await bobCipher.decryptFromSignal(
        receivedSecond,
      );

      final secondResult =
          utf8.decode(decryptedSecond);

      expect(
        secondResult,
        secondPlaintext,
      );

      // ------------------------------------------------------------
      // FINAL ASSERTIONS
      // ------------------------------------------------------------

      expect(
        await bobStore.containsSession(aliceAddress),
        isTrue,
      );

      print('');
      print('========================================');
      print('STELLAR E2E TEST PASSED');
      print('Alice -> Directory bundle -> X3DH');
      print('Alice -> encrypted message -> Bob');
      print('Bob -> decrypted plaintext');
      print('========================================');
      print('');
      } catch (e, stack) {
        fail('SIGNAL E2E FAILURE: $e\n$stack');
      }
    },
  );
}
