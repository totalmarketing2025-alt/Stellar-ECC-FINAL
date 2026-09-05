import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

import '../lib/core/crypto/directory_signal_adapter.dart';
import '../lib/core/network/directory_user_bundle.dart';

void main() {
  test(
    'Stellar Signal E2E: Alice encrypts and Bob decrypts via Directory bundle',
    () async {
      // ------------------------------------------------------------
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

      final transmitted =
          ciphertext.serialize();

      final received = PreKeySignalMessage(
        transmitted,
      );

      // ------------------------------------------------------------
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
    },
  );
}
