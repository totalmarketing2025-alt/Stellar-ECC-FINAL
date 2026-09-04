import 'dart:typed_data';

import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

import 'signal_stores.dart';
import 'signal_bundle_serializer.dart';
import 'directory_signal_adapter.dart';
import '../network/directory_client.dart';

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

  Future<PreKeyBundle> buildLocalPreKeyBundle() async {
    const deviceId = 1;

    final registrationId =
        await identityStore.getLocalRegistrationId();

    final identityKeyPair =
        await identityStore.getIdentityKeyPair();

    final preKey =
        await preKeyStore.loadFirstPreKey();

    if (preKey == null) {
      throw StateError('No one-time prekey available');
    }

    const signedPreKeyId = 0;
    final signedPreKey =
        await signedPreKeyStore.loadSignedPreKey(signedPreKeyId);

    return PreKeyBundle(
      registrationId,
      deviceId,
      preKey.id,
      preKey.getKeyPair().publicKey,
      signedPreKey.id,
      signedPreKey.getKeyPair().publicKey,
      signedPreKey.signature,
      identityKeyPair.getPublicKey(),
    );
  }

  /// Establishes a new session with a remote party via X3DH, given a
  /// prekey bundle fetched from the directory server.
  Future<void> establishSessionFromDirectory({
    required SignalProtocolAddress remoteAddress,
    required DirectoryUserBundle remoteBundle,
  }) async {
    final bundle =
        const DirectorySignalAdapter().toPreKeyBundle(remoteBundle);

    await establishSession(
      remoteAddress,
      bundle,
    );
  }

  /// Builds the public Signal prekey bundle that may be
  /// published to the Directory server.
  ///
  /// Private identity/prekey material never leaves the local stores.
  Future<Map<String, dynamic>> buildLocalDirectoryBundle() async {
    const serializer = SignalBundleSerializer();

    return serializer.buildBundle(
      identityStore: identityStore,
      preKeyStore: preKeyStore,
      signedPreKeyStore: signedPreKeyStore,
      deviceId: 1,
    );
  }

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
