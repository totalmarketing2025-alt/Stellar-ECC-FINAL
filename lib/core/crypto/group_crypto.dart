import 'dart:typed_data';

import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

import 'signal_stores.dart';
import 'session_manager.dart';

/// Sender Keys group encryption.
class GroupCrypto {
  GroupCrypto({
    required this.senderKeyStore,
    required this.sessionManager,
  });

  final StellarSenderKeyStore senderKeyStore;
  final SessionManager sessionManager;

  Future<dynamic> createOrRotateSenderKey(
    SenderKeyName groupSenderKeyName,
  ) async {
    final builder = GroupSessionBuilder(senderKeyStore);

    final distributionMessage =
        await builder.create(groupSenderKeyName);

    return distributionMessage;
  }

  Future<void> processIncomingDistributionMessage(
    SenderKeyName groupSenderKeyName,
    Uint8List distributionMessageBytes,
  ) async {
    final builder = GroupSessionBuilder(senderKeyStore);

    final distributionMessage =
        SenderKeyDistributionMessageWrapper(
          distributionMessageBytes,
        );

    await builder.process(
      groupSenderKeyName,
      distributionMessage,
    );
  }

  Future<Uint8List> encryptGroupMessage(
    SenderKeyName groupSenderKeyName,
    Uint8List plaintext,
  ) async {
    final cipher = GroupCipher(
      senderKeyStore,
      groupSenderKeyName,
    );

    final ciphertext = await cipher.encrypt(plaintext);

    return ciphertext;
  }

  Future<Uint8List> decryptGroupMessage(
    SenderKeyName groupSenderKeyName,
    Uint8List ciphertextBytes,
  ) async {
    final cipher = GroupCipher(
      senderKeyStore,
      groupSenderKeyName,
    );

    return cipher.decrypt(ciphertextBytes);
  }
}
