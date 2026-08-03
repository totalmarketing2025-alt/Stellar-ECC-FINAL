import 'dart:typed_data';

import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

import 'signal_stores.dart';
import 'session_manager.dart';

/// Sender Keys group encryption (Phase 3 §4). Each member encrypts once
/// with their own sender-key chain; distribution of that chain to other
/// members happens over each member's existing pairwise Double Ratchet
/// session, so key distribution itself is end-to-end protected.
///
/// Uses StellarSenderKeyStore (persistent, DB-backed) rather than
/// libsignal's InMemorySenderKeyStore — group state now survives an app
/// restart, closing the gap flagged during Module 4.
class GroupCrypto {
  GroupCrypto({
    required this.senderKeyStore,
    required this.sessionManager,
  });

  final StellarSenderKeyStore senderKeyStore;
  final SessionManager sessionManager;

  Future<void> createOrRotateSenderKey(SenderKeyName groupSenderKeyName) async {
    final builder = GroupSessionBuilder(senderKeyStore);
    final distributionMessage = await builder.create(groupSenderKeyName);
    // Caller is responsible for distributing `distributionMessage.serialize()`
    // to every other group member individually, encrypted via their pairwise
    // session (SessionManager.encryptForSend) — see domain/usecases/create_group.dart
    // and domain/usecases/rotate_group_key_on_membership_change.dart.
  }

  Future<void> processIncomingDistributionMessage(
    SenderKeyName groupSenderKeyName,
    Uint8List distributionMessageBytes,
  ) async {
    final builder = GroupSessionBuilder(senderKeyStore);
    final distributionMessage =
        SenderKeyDistributionMessage.fromSerialized(distributionMessageBytes);
    await builder.process(groupSenderKeyName, distributionMessage);
  }

  Future<Uint8List> encryptGroupMessage(
    SenderKeyName groupSenderKeyName,
    Uint8List plaintext,
  ) async {
    final cipher = GroupCipher(senderKeyStore, groupSenderKeyName);
    final ciphertext = await cipher.encrypt(plaintext);
    return ciphertext.serialize();
  }

  Future<Uint8List> decryptGroupMessage(
    SenderKeyName groupSenderKeyName,
    Uint8List ciphertextBytes,
  ) async {
    final cipher = GroupCipher(senderKeyStore, groupSenderKeyName);
    return cipher.decrypt(ciphertextBytes);
  }
}
