import 'dart:typed_data';

import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

import 'signal_stores.dart';

/// Thin orchestration over libsignal's SessionBuilder/SessionCipher/
/// GroupCipher — this class does not implement any cryptographic primitive
/// itself; it only sequences calls into the audited library. Mirrors the
/// Kotlin SessionManager from the earlier native-implementation phase,
/// ported to the Flutter/Dart stack.
class SessionManager {
  SessionManager({
    required this.identityStore,
    required this.preKeyStore,
    required this.signedPreKeyStore,
    required this.sessionStore,
  });

  final StellarIdentityKeyStore identityStore;
  final StellarPreKeyStore preKeyStore;
  final StellarSignedPreKeyStore signedPreKeyStore;
  final StellarSessionStore sessionStore;

  /// Establishes a new session with a remote party via X3DH, given a
  /// prekey bundle fetched from the directory server.
  Future<void> establishSession(
    SignalProtocolAddress remoteAddress,
    PreKeyBundle bundle,
  ) async {
    final builder = SessionBuilder(
      sessionStore,
      preKeyStore,
      signedPreKeyStore,
      identityStore,
      remoteAddress,
    );
    await builder.processPreKeyBundle(bundle);
  }

  Future<CiphertextMessage> encryptForSend(
    SignalProtocolAddress recipient,
    Uint8List plaintext,
  ) async {
    final cipher = SessionCipher(
      sessionStore,
      preKeyStore,
      signedPreKeyStore,
      identityStore,
      recipient,
    );
    // libsignal internally advances the Double Ratchet chain and selects
    // the configured AEAD (AES-256-GCM) for the derived message key.
    return cipher.encrypt(plaintext);
  }

  Future<Uint8List> decryptReceived(
    SignalProtocolAddress sender,
    CiphertextMessage ciphertext,
  ) async {
    final cipher = SessionCipher(
      sessionStore,
      preKeyStore,
      signedPreKeyStore,
      identityStore,
      sender,
    );

    if (ciphertext is PreKeySignalMessage) {
      // First message from this sender — establishes the session inline
      // via X3DH if one doesn't already exist.
      return cipher.decrypt(ciphertext);
    } else if (ciphertext is SignalMessage) {
      return cipher.decryptFromSignal(ciphertext);
    }
    throw ArgumentError('Unsupported ciphertext message type: ${ciphertext.runtimeType}');
  }

  Future<bool> hasSession(SignalProtocolAddress address) =>
      sessionStore.containsSession(address);
}
