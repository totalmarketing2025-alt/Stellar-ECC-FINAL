import 'dart:convert';
import 'dart:typed_data';

import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

import 'signal_stores.dart';

class SignalBundleSerializer {
  const SignalBundleSerializer();

  Future<Map<String, dynamic>> buildBundle({
    required StellarIdentityKeyStore identityStore,
    required StellarPreKeyStore preKeyStore,
    required StellarSignedPreKeyStore signedPreKeyStore,
    int deviceId = 1,
  }) async {
    final registrationId =
        await identityStore.getLocalRegistrationId();

    final identityKeyPair =
        await identityStore.getIdentityKeyPair();

    final preKey =
        await preKeyStore.loadFirstPreKey();

    if (preKey == null) {
      throw StateError(
        'No one-time prekey available for Directory registration',
      );
    }

    final signedPreKey =
        await signedPreKeyStore.loadSignedPreKey(0);

    final identityPublicKey =
        identityKeyPair.getPublicKey().serialize();

    final preKeyPublicKey =
        preKey.getKeyPair().publicKey.serialize();

    final signedPreKeyPublicKey =
        signedPreKey.getKeyPair().publicKey.serialize();

    return {
      'registrationId': registrationId,
      'deviceId': deviceId,
      'identityKey': base64Encode(identityPublicKey),
      'signedPreKey': {
        'keyId': signedPreKey.id,
        'publicKey': base64Encode(signedPreKeyPublicKey),
        'signature': base64Encode(signedPreKey.signature),
      },
      'preKey': {
        'keyId': preKey.id,
        'publicKey': base64Encode(preKeyPublicKey),
      },
    };
  }

  static Uint8List decodePublicKey(String value) {
    try {
      return Uint8List.fromList(base64Decode(value));
    } catch (_) {
      throw const FormatException(
        'Invalid base64 Signal public key',
      );
    }
  }
}
