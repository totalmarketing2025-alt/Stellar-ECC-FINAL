import 'dart:typed_data';
import 'dart:convert';

import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'package:uuid/uuid.dart';

import '../../core/storage/database.dart';
import '../../core/crypto/session_manager.dart';
import '../../core/network/relay_client.dart';
import '../../core/network/directory_client.dart';
import '../../core/network/envelope.dart';
import '../../core/media/media_attachment_service.dart';
import '../../core/media/attachment_payload.dart';
import '../../domain/models/message.dart';
import '../../domain/models/chat.dart';

/// Coordinates: encrypt (SessionManager) -> persist locally as plaintext
/// in the ephemeral store (StellarDatabase) -> send ciphertext over the
/// relay (RelayClient). This is the seam most UI/state code should talk
/// to rather than reaching into crypto/storage/network directly.
class ChatRepository {
  ChatRepository({
    required this.db,
    required this.sessionManager,
    required this.relayClient,
    required this.directoryClient,
    required this.localNickname,
    this.mediaService,
  });

  final StellarDatabase db;
  final SessionManager sessionManager;
  final RelayClient relayClient;
  final DirectoryClient directoryClient;
  final String localNickname;
  final MediaAttachmentService? mediaService;

  static const String _ackPrefix = 'STELLAR_ACK_V1:';

  Uint8List _encodeDeliveryAck(Uint8List deliveryToken) {
    return Uint8List.fromList(
      utf8.encode('$_ackPrefix${base64Encode(deliveryToken)}'),
    );
  }

  Uint8List? _decodeDeliveryAck(Uint8List plaintextBytes) {
    final text = utf8.decode(plaintextBytes, allowMalformed: false);
    if (!text.startsWith(_ackPrefix)) {
      return null;
    }

    final encodedToken = text.substring(_ackPrefix.length);
    try {
      return Uint8List.fromList(base64Decode(encodedToken));
    } catch (_) {
      return null;
    }
  }
  final _uuid = const Uuid();

  Future<List<Chat>> loadChats() async {
    final rows = await db.chatDao.all();
    return rows.map(Chat.fromRow).toList();
  }

  Future<List<Message>> loadMessages(String chatId) async {
    final rows = await db.messageDao.forChat(chatId);
    return rows.map(Message.fromRow).toList();
  }

  Future<void> deleteMessage(String messageId) async {
    await db.messageDao.secureDelete(messageId);
  }

  Future<Uint8List> loadAttachment(String blobId) async {
    final service = mediaService;
    if (service == null) {
      throw StateError('MediaAttachmentService is unavailable');
    }

    final row = await db.mediaBlobDao.byId(blobId);
    if (row == null) {
      throw StateError('Attachment $blobId not found');
    }

    final filePath = row['file_path'] as String;
    return service.loadAttachment(blobId, filePath);
  }


  Future<String?> findDirectChatId({
    required String peerName,
    required int peerDeviceId,
  }) async {
    final chats = await db.chatDao.all();

    for (final chat in chats) {
      if (chat['chat_type'] == 'direct' &&
          chat['peer_name'] == peerName &&
          chat['peer_device_id'] == peerDeviceId) {
        return chat['chat_id'] as String;
      }
    }

    return null;
  }

  Future<List<({String chatId, String peerName, int peerDeviceId})>>
      _knownDirectPeers() async {
    final chats = await db.chatDao.all();
    final result = <({String chatId, String peerName, int peerDeviceId})>[];

    for (final chat in chats) {
      if (chat['chat_type'] != 'direct') continue;

      final chatId = chat['chat_id'] as String;
      final peerName = chat['peer_name'] as String?;
      final peerDeviceId = chat['peer_device_id'] as int?;

      if (peerName == null ||
          peerName.isEmpty ||
          peerDeviceId == null) {
        continue;
      }

      result.add((
        chatId: chatId,
        peerName: peerName,
        peerDeviceId: peerDeviceId,
      ));
    }

    return result;
  }

  /// Encrypts, persists locally (plaintext, ephemeral, TTL-bound), and
  /// transmits `plaintext` to the recipient of `chatId`. For direct chats
  /// this is a single pairwise Double Ratchet encryption; groups route
  /// through GroupCrypto instead (see domain/usecases/send_group_message.dart).
  ///
  /// If `attachmentBytes` is supplied, it's encrypted at rest via
  /// MediaAttachmentService (per-attachment key, Phase 7/Module 7) and
  /// referenced from the message row; the ciphertext sent over the relay
  /// still only ever carries the Double-Ratchet-encrypted envelope — raw
  /// attachment bytes never touch the network layer unencrypted, and
  /// never touch the relay at all in this MVP (media stays device-to-
  /// device out of band in a full implementation; see docs note below).
  Future<void> _ensureDirectSession({
    required String peerName,
    required int peerDeviceId,
    bool forceSessionReset = false,
  }) async {
    final address = SignalProtocolAddress(
      peerName,
      peerDeviceId,
    );

    if (forceSessionReset) {
      await sessionManager.deleteSession(address);
    }

    if (await sessionManager.hasSession(address)) {
      return;
    }

    final remoteBundle =
        await directoryClient.lookupBundle(peerName);

    await sessionManager.establishSessionFromDirectory(
      remoteAddress: address,
      remoteBundle: remoteBundle,
    );
  }

  Future<Message> sendDirectMessage({
    required String chatId,
    required String plaintext,
    required int ttlSeconds,
    String? replyToId,
    Uint8List? attachmentBytes,
    String? attachmentMimeType,
    bool forceSessionReset = false,
  }) async {
    final chatRow = await db.chatDao.byId(chatId);
    final peerName = chatRow?['peer_name'] as String?;
    final peerDeviceId = chatRow?['peer_device_id'] as int?;

    if (peerName == null || peerName.isEmpty || peerDeviceId == null) {
      throw StateError('Direct chat peer mapping is missing for $chatId');
    }

    final messageId = _uuid.v4();

    // Stable per-message token used to correlate delivery ACKs.
    final deliveryToken =
        Uint8List.fromList(utf8.encode(_uuid.v4()).take(16).toList());

    // 1. Persist locally immediately (optimistic UI), status = sending.
    await db.messageDao.insert(
      messageId: messageId,
      chatId: chatId,
      senderId: localNickname,
      plaintext: plaintext,
      ttlSeconds: ttlSeconds,
      replyToId: replyToId,
      deliveryToken: deliveryToken,
    );

    try {
      if (attachmentBytes != null && attachmentMimeType != null && mediaService != null) {
        await mediaService!.storeAttachment(
          rawBytes: attachmentBytes,
          messageId: messageId,
          mimeType: attachmentMimeType,
          ttlSeconds: ttlSeconds,
        );
      }

      // 2. Encrypt via the Double Ratchet session with the recipient.
      print('SEND_STEP_1_BEFORE_SESSION');
      await _ensureDirectSession(
        peerName: peerName,
        peerDeviceId: peerDeviceId,
        forceSessionReset: forceSessionReset,
      ).timeout(
        const Duration(seconds: 15),
        onTimeout: () => throw StateError('SEND TIMEOUT: DIRECT SESSION'),
      );
      print('SEND_STEP_2_AFTER_SESSION');

      final address = SignalProtocolAddress(peerName, peerDeviceId);

      final plaintextBytes =
          attachmentBytes != null && attachmentMimeType != null
              ? AttachmentPayload.encode(
                  mimeType: attachmentMimeType,
                  bytes: attachmentBytes,
                )
              : Uint8List.fromList(utf8.encode(plaintext));

      print('SEND_STEP_3_BEFORE_ENCRYPT');
      final ciphertextMessage = await sessionManager.encryptForSend(address, plaintextBytes);
      print('SEND_STEP_4_AFTER_ENCRYPT');

      // 3. Wrap in the relay envelope. The delivery token is a fresh random
      // id per send — never the sender's static identity (sealed sender,
      // Phase 4 §2) — the relay only learns a rotating token and the
      // recipient's route.
      final envelope = Envelope(
        deliveryToken: deliveryToken,
        recipientRoute: peerName, // resolved server-side to an opaque route in production
        ciphertext: Uint8List.fromList(ciphertextMessage.serialize()),
      );
      // 4. Send the opaque encrypted envelope through the relay.
      print('SEND_STEP_5_BEFORE_RELAY');
      await relayClient.send(envelope.encode());
      print('SEND_STEP_6_AFTER_RELAY');
      await db.messageDao.updateStatus(messageId, 'sent');
      final debugRows = await db.messageDao.forChat(chatId);
      final debugMsg = debugRows.where((m) => m['message_id'] == messageId).firstOrNull;
      print('STATUS_DEBUG: messageId=$messageId status=${debugMsg?['status']}');

    } catch (e, st) {
      await db.messageDao.updateStatus(messageId, 'failed');
      print('SEND_DIRECT_MESSAGE_ERROR: $e');
      print('SEND_DIRECT_MESSAGE_STACK: $st');
      rethrow;
    }
    final rows = await db.messageDao.forChat(chatId);
    print('SEND_STEP_7_BEFORE_RETURN rows=${rows.length} messageId=$messageId');
    return rows.map(Message.fromRow).firstWhere((m) => m.messageId == messageId);
  }

  /// Handles an inbound envelope already routed to this chat by the
  /// caller (see presentation/state/relay_listener.dart in the next
  /// module, which demultiplexes incoming envelopes by sender before
  /// calling this).
  Future<void> _sendDeliveryAck({
    required SignalProtocolAddress recipient,
    required String recipientRoute,
    required Uint8List deliveryToken,
  }) async {
    final plaintext = _encodeDeliveryAck(deliveryToken);

    final ciphertextMessage =
        await sessionManager.encryptForSend(recipient, plaintext);

    // Use a fresh relay token for the ACK itself. The original delivery
    // token remains inside the Signal-encrypted ACK payload.
    final ackRelayToken =
        Uint8List.fromList(utf8.encode(_uuid.v4()).take(16).toList());

    final envelope = Envelope(
      deliveryToken: ackRelayToken,
      recipientRoute: recipientRoute,
      ciphertext: Uint8List.fromList(ciphertextMessage.serialize()),
    );

    await relayClient.send(envelope.encode());
  }

  Future<Message?> receiveEnvelope({
    required Uint8List rawEnvelope,
  }) async {
    final envelope = Envelope.decode(rawEnvelope);
    final peers = await _knownDirectPeers();

    if (peers.isEmpty) {
      throw StateError('No known direct peer session can receive this envelope');
    }

    late final String chatId;
    late final String senderNickname;
    late final SignalProtocolAddress senderAddress;
    late final Uint8List plaintextBytes;

    Object? lastError;

    for (final peer in peers) {
      final address = SignalProtocolAddress(
        peer.peerName,
        peer.peerDeviceId,
      );

      try {
        final signalMessage = (envelope.ciphertext.isNotEmpty &&
                (envelope.ciphertext[0] & 0x07) ==
                    CiphertextMessage.prekeyType)
            ? PreKeySignalMessage(envelope.ciphertext)
            : SignalMessage.fromSerialized(envelope.ciphertext);

        final decrypted = await sessionManager.decryptReceived(
          address,
          signalMessage,
        );

        chatId = peer.chatId;
        senderNickname = peer.peerName;
        senderAddress = address;
        plaintextBytes = decrypted;
        lastError = null;
        break;
      } catch (error) {
        lastError = error;
      }
    }

    if (lastError != null) {
      throw StateError(
        'Unable to decrypt envelope with any known direct peer session: $lastError',
      );
    }

    // ACKs are Signal-encrypted control messages. They must be handled
    // immediately after decryption and must never become chat messages.
    final ackToken = _decodeDeliveryAck(plaintextBytes);
    if (ackToken != null) {
      await db.messageDao.markDeliveredByToken(ackToken);
      return null;
    }

    final attachment = AttachmentPayload.decode(plaintextBytes);
    final plaintext =
        attachment != null ? '📎 Attachment' : utf8.decode(plaintextBytes);
    final messageId = _uuid.v4();

    final chatRow = await db.chatDao.byId(chatId);
    if (chatRow == null) {
      throw StateError('Direct chat not found for $senderNickname');
    }

    final ttl = chatRow['default_ttl_sec'] as int;

    await db.messageDao.insert(
      messageId: messageId,
      chatId: chatId,
      senderId: senderNickname,
      plaintext: plaintext,
      ttlSeconds: ttl,
    );

    if (attachment != null) {
      final service = mediaService;
      if (service == null) {
        throw StateError(
          'Received attachment but MediaAttachmentService is unavailable',
        );
      }

      await service.storeAttachment(
        rawBytes: attachment.bytes,
        messageId: messageId,
        mimeType: attachment.mimeType,
        ttlSeconds: ttl,
      );
    }

    // The message has been successfully decrypted and stored locally.
    await db.messageDao.updateStatus(messageId, 'delivered');

    // Tell the sender that this exact envelope was successfully delivered.
    // ACK failure must not make us lose an already received message.
    try {
      await _sendDeliveryAck(
        recipient: senderAddress,
        recipientRoute: senderNickname,
        deliveryToken: envelope.deliveryToken,
      );
    } catch (error, stackTrace) {
      print('DELIVERY_ACK_SEND_ERROR: $error');
      print('DELIVERY_ACK_SEND_STACK: $stackTrace');
    }

    final rows = await db.messageDao.forChat(chatId);
    return rows
        .map(Message.fromRow)
        .firstWhere((m) => m.messageId == messageId);
  }



  Future<void> addReaction(String messageId, String emoji) async {
    await db.reactionDao.add(messageId, localNickname, emoji);
  }

  Future<void> updateChatTtl(String chatId, int ttlSeconds) async {
    await db.chatDao.updateDefaultTtl(chatId, ttlSeconds);
  }

  Future<void> createDirectChat({
    required String chatId,
    required String displayName,
    required String peerName,
    required int peerDeviceId,
  }) async {
    final existing = await db.chatDao.byId(chatId);
    if (existing != null) return;

    await db.chatDao.insert(
      chatId: chatId,
      chatType: "direct",
      displayName: displayName,
      defaultTtlSec: 3600,
      peerName: peerName,
      peerDeviceId: peerDeviceId,
    );
  }

}
