import 'dart:convert';
import 'dart:typed_data';

import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

import '../network/directory_client.dart';
import '../network/directory_user_bundle.dart';

/// Converts the public material returned by Directory into libsignal's
/// PreKeyBundle.
///
/// This adapter is deliberately isolated from DirectoryClient so the
/// transport/API representation can change without touching session code.
class DirectorySignalAdapter {
  const DirectorySignalAdapter();

  PreKeyBundle toPreKeyBundle(DirectoryUserBundle remote) {
    final identityKey =
        IdentityKey.fromBytes(_decodeBase64(remote.identityKey), 0);

    final signedPreKeyPublic =
        Curve.decodePoint(_decodeBase64(remote.signedPreKey), 0);

    final signedPreKeySignature =
        _decodeBase64(remote.signedPreKeySignature);

    ECPublicKey? preKeyPublic;
    if (remote.preKey != null) {
      preKeyPublic =
          Curve.decodePoint(_decodeBase64(remote.preKey!), 0);
    }

    return PreKeyBundle(
      remote.registrationId,
      remote.deviceId,
      remote.preKeyId,
      preKeyPublic,
      remote.signedPreKeyId,
      signedPreKeyPublic,
      signedPreKeySignature,
      identityKey,
    );
  }

  Uint8List _decodeBase64(String value) {
    try {
      return Uint8List.fromList(base64Decode(value));
    } catch (_) {
      throw const FormatException(
        'Invalid base64 Signal key returned by Directory',
      );
    }
  }
}
