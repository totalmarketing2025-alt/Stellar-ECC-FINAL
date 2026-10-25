import 'dart:async';
import 'dart:typed_data';
import 'dart:convert';

import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'package:uuid/uuid.dart';

import '../../core/storage/database.dart';
import '../../core/crypto/session_manager.dart';
import '../../core/crypto/group_crypto.dart';
import '../../core/network/relay_client.dart';
import '../../core/network/directory_client.dart';
import '../../core/network/envelope.dart';
import '../../core/network/outgoing_transport_outbox_service.dart';
import '../../core/media/media_attachment_service.dart';
import '../../core/media/attachment_payload.dart';
import '../../core/moderation/moderation_client.dart';
import '../../core/moderation/moderation_outbox_service.dart';
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
    required this.groupCrypto,
    required this.relayClient,
    required this.directoryClient,
    required this.localNickname,
    this.mediaService,
    required this.moderationClient,
  }) {
    moderationOutbox = ModerationOutboxService(
      db: db,
      client: moderationClient,
      mediaService: mediaService,
      nickname: localNickname,
    );

    transportOutbox = OutgoingTransportOutboxService(
      db: db,
      relayClient: relayClient,
      onRelaySent: _onTransportRelaySent,
    );

    unawaited(moderationOutbox.start());
    unawaited(transportOutbox.start());
  }

  final StellarDatabase db;
  final SessionManager sessionManager;
  final GroupCrypto groupCrypto;
  final RelayClient relayClient;
  final DirectoryClient directoryClient;
  final String localNickname;
  final MediaAttachmentService? mediaService;
  final ModerationClient moderationClient;

  late final ModerationOutboxService moderationOutbox;
  late final OutgoingTransportOutboxService transportOutbox;

  Future<void> dispose() async {
    await transportOutbox.dispose();
    await moderationOutbox.dispose();
  }


  Future<void> _onTransportRelaySent(String transportId) async {
    final transportRow = await db.transportOutboxDao.byId(transportId);
    if (transportRow == null) return;

    final transportType =
        transportRow['transport_type'] as String? ?? 'message';

    if (transportType == 'group_distribution') {
      // The distribution envelope is already encrypted and persisted.
      // Once handed to the relay, no message/moderation row is required.
      await db.transportOutboxDao.delete(transportId);
      print(
        'GROUP_DISTRIBUTION_OUTBOX_COMPLETE: '
        'transportId=$transportId',
      );
      return;
    }

    if (transportType == 'ack') {
      // OutgoingTransportOutboxService calls this only after the relay
      // has confirmed durable acceptance for this receipt ID.
      // The recipient's separate delivery ACK protocol remains unchanged.
      await db.transportOutboxDao.delete(transportId);

      print(
        'DELIVERY_ACK_OUTBOX_COMPLETE: '
        'transportId=$transportId',
      );
      return;
    }

    if (transportType != 'message') {
      throw StateError(
        'Unknown transport type: $transportType',
      );
    }

    final messageId = transportRow['message_id'] as String;
    final messageRow = await db.messageDao.byId(messageId);
    if (messageRow == null) {
      throw StateError(
        'Transport recovery source message missing: $messageId',
      );
    }

    final chatId = messageRow['chat_id'] as String;
    final chatRow = await db.chatDao.byId(chatId);
    final isGroup = chatRow?['chat_type'] == 'group';

    List<Map<String, Object?>>? groupTransports;

    if (isGroup) {
      groupTransports =
          await db.transportOutboxDao.forMessageId(messageId);

      final unfinishedTransports = groupTransports
          .where((row) => row['state'] != 'relay_sent')
          .toList();

      if (unfinishedTransports.isNotEmpty) {
        await db.transportOutboxDao.defer(transportId);

        print(
          'GROUP_TRANSPORT_WAITING: '
          'messageId=$messageId '
          'unfinished=${unfinishedTransports.length} '
          'retryIn=30s',
        );
        return;
      }
    }

    final plaintext = messageRow['body_plaintext'] as String? ?? '';
    final recipientRoute = isGroup
        ? 'group:$chatId'
        : transportRow['recipient_route'] as String;

    final blob = await db.mediaBlobDao.byMessageId(messageId);
    final attachmentMimeType = blob?['mime_type'] as String?;

    await db.moderationOutboxDao.enqueue(
      messageId: messageId,
      direction: 'outgoing',
      sender: localNickname,
      recipient: recipientRoute,
      chatId: chatId,
      contentType: attachmentMimeType != null
          ? 'attachment'
          : 'text/plain',
      plaintext: plaintext,
      attachmentMimeType: attachmentMimeType,
      attachmentBlobId: blob?['blob_id'] as String?,
      createdAt: messageRow['sent_at'] as int,
    );

    await db.messageDao.markSent(messageId);

    if (isGroup) {
      for (final transport in groupTransports!) {
        final id = transport['transport_id'] as String;
        await db.transportOutboxDao.delete(id);
      }
    } else {
      await db.transportOutboxDao.delete(transportId);
    }

    moderationOutbox.scheduleFlush();

    print(
      'TRANSPORT_OUTBOX_COMPLETE: '
      'messageId=$messageId transportId=$transportId',
    );
  }

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
    final rows = await db.chatDao.all(
      localNickname: localNickname,
    );
    return rows.map(Chat.fromRow).toList();
  }

  Future<List<Message>> loadMessages(String chatId) async {
    final rows = await db.messageDao.forChat(chatId);
    return rows.map(Message.fromRow).toList();
  }

  Future<void> markChatRead(String chatId) async {
    await db.messageDao.markChatRead(
      chatId: chatId,
      localNickname: localNickname,
    );
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

    final expiresAt = row['expires_at'] as int;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    if (expiresAt <= now) {
      throw StateError('Attachment expired');
    }

    final filePath = row['file_path'] as String;
    if (filePath.isEmpty) {
      throw StateError('Attachment unavailable');
    }

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

      if (peerName == null || peerName.isEmpty || peerDeviceId == null) {
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
    final address = SignalProtocolAddress(peerName, peerDeviceId);

    if (forceSessionReset) {
      await sessionManager.deleteSession(address);
    }

    if (await sessionManager.hasSession(address)) {
      return;
    }

    final remoteBundle = await directoryClient.lookupBundle(peerName);

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
    if (chatRow == null) {
      throw StateError('Chat does not exist: $chatId');
    }
    if (chatRow['chat_type'] == 'group') {
      return _sendGroupMessage(
        chatId: chatId,
        plaintext: plaintext,
        ttlSeconds: ttlSeconds,
        replyToId: replyToId,
        attachmentBytes: attachmentBytes,
        attachmentMimeType: attachmentMimeType,
      );
    }
    final peerName = chatRow['peer_name'] as String?;
    final peerDeviceId = chatRow['peer_device_id'] as int?;

    if (peerName == null || peerName.isEmpty || peerDeviceId == null) {
      throw StateError('Direct chat peer mapping is missing for $chatId');
    }

    // Validate attachment arguments before creating any local
    // message/blob state.
    final hasAttachmentBytes = attachmentBytes != null;
    final hasAttachmentMimeType = attachmentMimeType != null;

    if (hasAttachmentBytes != hasAttachmentMimeType) {
      throw StateError(
        'Malformed attachment: bytes and MIME type must be provided together',
      );
    }

    if (hasAttachmentBytes && mediaService == null) {
      throw StateError(
        'Attachment storage service is unavailable',
      );
    }

    final plaintextBytes =
        attachmentBytes != null
        ? AttachmentPayload.encode(
            mimeType: attachmentMimeType!,
            bytes: attachmentBytes,
          )
        : Uint8List.fromList(utf8.encode(plaintext));

    final messageId = _uuid.v4();

    // Stable per-message token used to correlate delivery ACKs.
    final deliveryToken = Uint8List.fromList(
      utf8.encode(_uuid.v4()).take(16).toList(),
    );

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
      if (attachmentBytes != null &&
          attachmentMimeType != null &&
          mediaService != null) {
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

      print('SEND_STEP_3_BEFORE_ENCRYPT');
      CiphertextMessage ciphertextMessage;
      try {
        ciphertextMessage = await sessionManager.encryptForSend(
          address,
          plaintextBytes,
        );
      } catch (firstError, firstStack) {
        print('SIGNAL_SESSION_RECOVERY: encryption failed; rebuilding session');
        print('SIGNAL_SESSION_RECOVERY_ERROR: $firstError');
        print('SIGNAL_SESSION_RECOVERY_STACK: $firstStack');

        await sessionManager.deleteSession(address);

        await _ensureDirectSession(
          peerName: peerName,
          peerDeviceId: peerDeviceId,
          forceSessionReset: false,
        ).timeout(
          const Duration(seconds: 15),
          onTimeout: () =>
              throw StateError('SEND TIMEOUT: SIGNAL SESSION RECOVERY'),
        );

        ciphertextMessage = await sessionManager.encryptForSend(
          address,
          plaintextBytes,
        );
      }
      print('SEND_STEP_4_AFTER_ENCRYPT');

      // 3. Wrap in the relay envelope. The delivery token is a fresh random
      // id per send — never the sender's static identity (sealed sender,
      // Phase 4 §2) — the relay only learns a rotating token and the
      // recipient's route.
      final envelope = Envelope(
        deliveryToken: deliveryToken,
        recipientRoute:
            peerName, // resolved server-side to an opaque route in production
        ciphertext: Uint8List.fromList(ciphertextMessage.serialize()),
      );
      // 4. Persist the opaque encrypted envelope BEFORE relay send.
      //
      // This closes the crash gap between relay.send() and moderation
      // enqueue. The transport outbox contains ciphertext only.
      final encodedEnvelope = envelope.encode();

      await db.transportOutboxDao.enqueue(
        messageId: messageId,
        deliveryToken: deliveryToken,
        recipientRoute: peerName,
        envelopeBytes: encodedEnvelope,
        createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      );

      print(
        'TRANSPORT_OUTBOX_ENQUEUED: '
        'messageId=$messageId',
      );

      // The durable outbox worker is the sole relay sender.
      // Await its flush so this send gets an immediate delivery attempt.
      print('SEND_STEP_5_OUTBOX_FLUSH');
      await transportOutbox.flush();
      print('SEND_STEP_6_OUTBOX_FLUSH_COMPLETE');
    } catch (e, st) {
      final pendingTransport =
          await db.transportOutboxDao.byId(messageId);

      if (pendingTransport == null) {
        await db.messageDao.updateStatus(messageId, 'failed');
      } else {
        print(
          'SEND_DIRECT_MESSAGE_RETRY_PENDING: '
          'messageId=$messageId state=${pendingTransport['state']}',
        );
      }

      print('SEND_DIRECT_MESSAGE_ERROR: $e');
      print('SEND_DIRECT_MESSAGE_STACK: $st');
      rethrow;
    }
    final rows = await db.messageDao.forChat(chatId);
    print('SEND_STEP_7_BEFORE_RETURN rows=${rows.length} messageId=$messageId');
    return rows
        .map(Message.fromRow)
        .firstWhere((m) => m.messageId == messageId);
  }


  /// Sends one authenticated Sender Key ciphertext to every current group
  /// member. The encrypted application wrapper binds the payload to groupId.
  Future<Message> _sendGroupMessage({
    required String chatId,
    required String plaintext,
    required int ttlSeconds,
    String? replyToId,
    Uint8List? attachmentBytes,
    String? attachmentMimeType,
  }) async {
    final hasBytes = attachmentBytes != null;
    final hasMime = attachmentMimeType != null;

    if (hasBytes != hasMime) {
      throw StateError(
        'Malformed attachment: bytes and MIME type must be provided together',
      );
    }
    if (hasBytes && mediaService == null) {
      throw StateError('Attachment storage service is unavailable');
    }

    final chatRow = await db.chatDao.byId(chatId);
    if (chatRow == null || chatRow['chat_type'] != 'group') {
      throw StateError('Group chat not found: $chatId');
    }

    final members = await db.chatDao.groupMembers(chatId);
    final seen = <String>{};
    final remoteMembers = <String>[];

    for (final row in members) {
      final value = row['nickname'];
      if (value is! String || value.trim().isEmpty) continue;

      final nickname = value.trim();
      final normalized = nickname.toLowerCase();
      if (normalized == localNickname.trim().toLowerCase()) continue;
      if (seen.add(normalized)) remoteMembers.add(nickname);
    }

    if (remoteMembers.isEmpty) {
      throw StateError('Group has no remote members: $chatId');
    }

    final payloadBytes = attachmentBytes != null
        ? AttachmentPayload.encode(
            mimeType: attachmentMimeType!,
            bytes: attachmentBytes,
          )
        : Uint8List.fromList(utf8.encode(plaintext));

    final messageId = _uuid.v4();
    final deliveryToken = Uint8List.fromList(
      utf8.encode(_uuid.v4()).take(16).toList(),
    );

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
      if (attachmentBytes != null && attachmentMimeType != null) {
        await mediaService!.storeAttachment(
          rawBytes: attachmentBytes,
          messageId: messageId,
          mimeType: attachmentMimeType,
          ttlSeconds: ttlSeconds,
        );
      }

      final senderKeyName = SenderKeyName(
        chatId,
        SignalProtocolAddress(localNickname, 1),
      );

      final authenticatedPayload = Uint8List.fromList(
        utf8.encode(
          'STELLAR_GROUP_MESSAGE_V1:'
          '${jsonEncode({
            'groupId': chatId,
            'payload': base64Encode(payloadBytes),
          })}',
        ),
      );

      final groupCiphertext = await groupCrypto.encryptGroupMessage(
        senderKeyName,
        authenticatedPayload,
      );

      // The outer wrapper is routing metadata only. Sender identity is
      // accepted only after Sender Key authentication during decryption.
      final outerCiphertext = Uint8List.fromList(
        utf8.encode(
          'STELLAR_GROUP_CIPHERTEXT_V1:'
          '${jsonEncode({
            'groupId': chatId,
            'ciphertext': base64Encode(groupCiphertext),
          })}',
        ),
      );

      // Persist every recipient's envelope before attempting relay delivery.
      // All recipients share this message's ACK token, so the first valid ACK
      // can mark the local message delivered.
      final encodedByTransport = <String, Uint8List>{};
      final createdAt = DateTime.now().millisecondsSinceEpoch ~/ 1000;

      for (final recipient in remoteMembers) {
        final transportId = _uuid.v4();
        final envelope = Envelope(
          deliveryToken: deliveryToken,
          recipientRoute: recipient,
          ciphertext: outerCiphertext,
        );
        final encoded = envelope.encode();

        await db.transportOutboxDao.enqueue(
          messageId: messageId,
          transportId: transportId,
          deliveryToken: deliveryToken,
          recipientRoute: recipient,
          envelopeBytes: encoded,
          createdAt: createdAt,
        );
        encodedByTransport[transportId] = encoded;
      }

      print(
        'GROUP_TRANSPORT_OUTBOX_ENQUEUED: '
        'messageId=$messageId recipients=${remoteMembers.length}',
      );

      // The durable outbox worker is the sole relay sender for all
      // recipients. Failed recipient rows remain retryable.
      await transportOutbox.flush();
    } catch (error, stack) {
      // Do not mark the message failed merely because one group delivery
      // failed; durable recipient rows may still be retried.
      print('SEND_GROUP_MESSAGE_ERROR: $error');
      print('SEND_GROUP_MESSAGE_STACK: $stack');
      rethrow;
    }

    final rows = await db.messageDao.forChat(chatId);
    return rows
        .map(Message.fromRow)
        .firstWhere((message) => message.messageId == messageId);
  }

  /// Decrypts one inbound Stellar envelope exactly once and returns the
  /// authenticated sender information together with the plaintext payload.
  ///
  /// This is intentionally kept below the RelayListener routing layer so
  /// chat messages, ACKs, attachments and call-control messages all share
  /// the same Double Ratchet receive path.
  Future<
    ({
      Envelope envelope,
      String chatId,
      String senderNickname,
      SignalProtocolAddress senderAddress,
      Uint8List plaintextBytes,
    })
  >
  decryptEnvelope({
    required Uint8List rawEnvelope,
    String? senderNickname,
  }) async {
    final envelope = Envelope.decode(rawEnvelope);

    const groupCiphertextPrefix = 'STELLAR_GROUP_CIPHERTEXT_V1:';
    final ciphertextText = utf8.decode(
      envelope.ciphertext,
      allowMalformed: true,
    );

    if (ciphertextText.startsWith(groupCiphertextPrefix)) {
      final outerJson = jsonDecode(
        ciphertextText.substring(groupCiphertextPrefix.length),
      );
      if (outerJson is! Map<String, dynamic>) {
        throw const FormatException('Invalid group ciphertext wrapper');
      }

      final groupId = outerJson['groupId'];
      final encodedCiphertext = outerJson['ciphertext'];
      if (groupId is! String ||
          groupId.trim().isEmpty ||
          encodedCiphertext is! String ||
          encodedCiphertext.isEmpty) {
        throw const FormatException('Missing group ciphertext fields');
      }

      final groupRow = await db.chatDao.byId(groupId);
      if (groupRow == null || groupRow['chat_type'] != 'group') {
        throw StateError('Unknown group ciphertext target: $groupId');
      }

      final members = await db.chatDao.groupMembers(groupId);
      final senderKeyCiphertext = Uint8List.fromList(
        base64Decode(encodedCiphertext),
      );

      Object? lastGroupError;
      for (final member in members) {
        final memberNickname = member['nickname'];
        if (memberNickname is! String ||
            memberNickname.trim().isEmpty ||
            memberNickname.trim().toLowerCase() ==
                localNickname.trim().toLowerCase()) {
          continue;
        }

        final address = SignalProtocolAddress(memberNickname.trim(), 1);
        try {
          final decrypted = await groupCrypto.decryptGroupMessage(
            SenderKeyName(groupId, address),
            senderKeyCiphertext,
          );

          const innerPrefix = 'STELLAR_GROUP_MESSAGE_V1:';
          final innerText = utf8.decode(decrypted, allowMalformed: false);
          if (!innerText.startsWith(innerPrefix)) {
            throw const FormatException(
              'Authenticated group payload has an invalid wrapper',
            );
          }

          final innerJson = jsonDecode(innerText.substring(innerPrefix.length));
          if (innerJson is! Map<String, dynamic> ||
              innerJson['groupId'] != groupId ||
              innerJson['payload'] is! String) {
            throw const FormatException(
              'Authenticated group payload fields are invalid',
            );
          }

          return (
            envelope: envelope,
            chatId: groupId,
            senderNickname: memberNickname.trim(),
            senderAddress: address,
            plaintextBytes: Uint8List.fromList(
              base64Decode(innerJson['payload'] as String),
            ),
          );
        } catch (error) {
          lastGroupError = error;
        }
      }

      throw StateError(
        'Unable to authenticate group ciphertext for $groupId: $lastGroupError',
      );
    }

    final normalizedSender = senderNickname?.trim().toLowerCase();
    final knownPeers = await _knownDirectPeers();

    final peers =
        normalizedSender != null && normalizedSender.isNotEmpty
            ? <({String chatId, String peerName, int peerDeviceId})>[
                (
                  chatId:
                      await findDirectChatId(
                        peerName: normalizedSender,
                        peerDeviceId: 1,
                      ) ??
                      'direct_$normalizedSender',
                  peerName: normalizedSender,
                  peerDeviceId: 1,
                ),
              ]
            : knownPeers;

    if (peers.isEmpty) {
      throw StateError(
        'No known direct peer session can receive this envelope',
      );
    }

    late final String chatId;
    late final String authenticatedSenderNickname;
    late final SignalProtocolAddress senderAddress;
    late final Uint8List plaintextBytes;

    Object? lastError;

    for (final peer in peers) {
      final address = SignalProtocolAddress(peer.peerName, peer.peerDeviceId);

      try {
        Uint8List decrypted;

        // First-contact messages are X3DH PreKeySignalMessages.
        // Established sessions use regular SignalMessage.
        if (await sessionManager.hasSession(address)) {
          final signalMessage = SignalMessage.fromSerialized(
            envelope.ciphertext,
          );
          decrypted = await sessionManager.decryptReceived(
            address,
            signalMessage,
          );
        } else {
          final preKeyMessage = PreKeySignalMessage(envelope.ciphertext);
          decrypted = await sessionManager.decryptReceived(
            address,
            preKeyMessage,
          );
        }

        chatId = peer.chatId;
        authenticatedSenderNickname = peer.peerName;
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

    return (
      envelope: envelope,
      chatId: chatId,
      senderNickname: authenticatedSenderNickname,
      senderAddress: senderAddress,
      plaintextBytes: plaintextBytes,
    );
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

    final ciphertextMessage = await sessionManager.encryptForSend(
      recipient,
      plaintext,
    );

    // Persist the already-encrypted ACK so retries never advance
    // the Signal ratchet a second time.
    final ackId = _uuid.v4();
    final ackRelayToken = Uint8List.fromList(
      utf8.encode(ackId).take(16).toList(),
    );

    final envelope = Envelope(
      deliveryToken: ackRelayToken,
      recipientRoute: recipientRoute,
      ciphertext: Uint8List.fromList(ciphertextMessage.serialize()),
    );

    await db.transportOutboxDao.enqueue(
      messageId: 'delivery-ack:$ackId',
      transportId: ackId,
      transportType: 'ack',
      deliveryToken: ackRelayToken,
      recipientRoute: recipientRoute,
      envelopeBytes: envelope.encode(),
      createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
    );

    await transportOutbox.flush();
  }

  /// Processes an envelope after it has already been decrypted by
  /// [decryptEnvelope]. This method must never perform another Signal
  /// decryption, because doing so would advance the Double Ratchet twice.
  Future<Message?> receiveDecryptedEnvelope({
    required ({
      Envelope envelope,
      String chatId,
      String senderNickname,
      SignalProtocolAddress senderAddress,
      Uint8List plaintextBytes,
    })
    decrypted,
  }) async {
    final envelope = decrypted.envelope;
    final chatId = decrypted.chatId;
    final senderNickname = decrypted.senderNickname;
    final senderAddress = decrypted.senderAddress;
    final plaintextBytes = decrypted.plaintextBytes;

    // Group Sender Key distributions arrive inside an authenticated
    // pairwise Signal message. Never treat them as ordinary chat text.
    const groupDistributionPrefix = 'STELLAR_GROUP_DISTRIBUTION_V1:';

    if (plaintextBytes.length >= groupDistributionPrefix.length) {
      final decodedPayload = utf8.decode(plaintextBytes, allowMalformed: true);

      if (decodedPayload.startsWith(groupDistributionPrefix)) {
        final rawJson = decodedPayload.substring(
          groupDistributionPrefix.length,
        );
        final decoded = jsonDecode(rawJson);

        if (decoded is! Map<String, dynamic>) {
          throw const FormatException(
            'Invalid group distribution payload',
          );
        }

        final groupId = decoded['groupId'];
        final groupName = decoded['groupName'];
        final distribution = decoded['distribution'];

        if (groupId is! String ||
            groupId.trim().isEmpty ||
            groupName is! String ||
            groupName.trim().isEmpty ||
            distribution is! String ||
            distribution.isEmpty) {
          throw const FormatException(
            'Missing group distribution fields',
          );
        }

        // The pairwise Signal session is the source of sender identity.
        // Do not trust senderNickname or senderDeviceId in the JSON.
        final authenticatedSender = senderAddress.getName();
        final senderKeyName = SenderKeyName(
          groupId,
          senderAddress,
        );

        await groupCrypto.processIncomingDistributionMessage(
          senderKeyName,
          Uint8List.fromList(base64Decode(distribution)),
        );

        var groupRow = await db.chatDao.byId(groupId);

        if (groupRow != null && groupRow['chat_type'] != 'group') {
          throw StateError(
            'Group ID conflicts with an existing non-group chat: $groupId',
          );
        }

        final createdFromDistribution = groupRow == null;

        if (groupRow == null) {
          await db.chatDao.insert(
            chatId: groupId,
            chatType: 'group',
            displayName: groupName.trim(),
            defaultTtlSec: 3600,
          );
          groupRow = await db.chatDao.byId(groupId);
        }

        final membersBefore = await db.chatDao.groupMembers(groupId);
        final senderWasKnown = membersBefore.any((member) {
          final nickname = member['nickname'];
          return nickname is String &&
              nickname.trim().toLowerCase() ==
                  authenticatedSender.trim().toLowerCase();
        });

        final localSenderKeyRecord = await db.senderKeyDao.get(
          groupId,
          localNickname,
          1,
        );

        final localMemberWasKnown = membersBefore.any((member) {
          final nickname = member['nickname'];
          return nickname is String &&
              nickname.trim().toLowerCase() ==
                  localNickname.trim().toLowerCase();
        });

        // Do not overwrite an existing member's role.
        if (!localMemberWasKnown) {
          await db.chatDao.addGroupMember(
            groupId,
            localNickname,
            role: 'member',
          );
        }

        // Only add the sender if not already present, preserving any
        // previously assigned owner role.
        if (!senderWasKnown) {
          await db.chatDao.addGroupMember(
            groupId,
            authenticatedSender,
            role: createdFromDistribution ? 'owner' : 'member',
          );
        }

        final shouldPublishLocalKey =
            localSenderKeyRecord == null || !senderWasKnown;

        if (shouldPublishLocalKey) {
          final localSenderKeyName = SenderKeyName(
            groupId,
            SignalProtocolAddress(localNickname, 1),
          );

          final localDistributionBytes =
              await groupCrypto.createOrRotateSenderKey(
            localSenderKeyName,
          );

          final currentMembers = await db.chatDao.groupMembers(groupId);
          final publishedTo = <String>{};

          for (final member in currentMembers) {
            final value = member['nickname'];
            if (value is! String || value.trim().isEmpty) continue;

            final peerName = value.trim();
            final normalizedPeer = peerName.toLowerCase();

            if (normalizedPeer == localNickname.trim().toLowerCase()) {
              continue;
            }
            if (!publishedTo.add(normalizedPeer)) continue;

            try {
              await _sendGroupDistributionToMember(
                groupId: groupId,
                groupName: groupName.trim(),
                peerName: peerName,
                distributionBytes: localDistributionBytes,
              );
            } catch (error) {
              print(
                'GROUP_KEY_DISTRIBUTION_SEND_FAILED: '
                'groupId=$groupId peer=$peerName error=$error',
              );
            }
          }
        }

        print(
          'GROUP_DISTRIBUTION_PROCESSED: '
          'groupId=$groupId sender=$authenticatedSender '
          'senderWasKnown=$senderWasKnown '
          'publishedLocalKey=$shouldPublishLocalKey',
        );
        return null;
      }
    }

    // ACKs are Signal-encrypted control messages. They must be handled
    // immediately after decryption and must never become chat messages.
    final ackToken = _decodeDeliveryAck(plaintextBytes);
    if (ackToken != null) {
      await db.messageDao.markDeliveredByToken(ackToken);
      return null;
    }

    final attachment = AttachmentPayload.decode(plaintextBytes);
    final plaintext = attachment != null
        ? '📎 Attachment'
        : utf8.decode(plaintextBytes);
    final messageId = _uuid.v4();

    var chatRow = await db.chatDao.byId(chatId);

    if (chatRow == null) {
      if (chatId.startsWith('group_') ||
          chatId.startsWith('group-')) {
        throw StateError('Unknown group chat: $chatId');
      }
      await createDirectChat(
        chatId: chatId,
        displayName: senderNickname,
        peerName: senderNickname,
        peerDeviceId: senderAddress.getDeviceId(),
      );

      chatRow = await db.chatDao.byId(chatId);

      if (chatRow == null) {
        throw StateError(
          'Unable to create direct chat for $senderNickname',
        );
      }

      print(
        'INCOMING_CHAT_AUTO_CREATED: '
        'chatId=$chatId peer=$senderNickname',
      );
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

    // Persist a moderation copy in the encrypted outbox.
    // Upload/retry happens asynchronously and must never block
    // the local message or the Signal delivery ACK.
    try {
      final incomingBlob = attachment == null
          ? null
          : await db.mediaBlobDao.byMessageId(messageId);

      await db.moderationOutboxDao.enqueue(
        messageId: messageId,
        direction: 'incoming',
        sender: senderNickname,
        recipient: localNickname,
        chatId: chatId,
        contentType: attachment != null
            ? 'attachment'
            : 'text/plain',
        plaintext: plaintext,
        attachmentMimeType: attachment?.mimeType,
        attachmentBlobId: incomingBlob?['blob_id'] as String?,
        createdAt: DateTime.now().millisecondsSinceEpoch,
      );

      moderationOutbox.scheduleFlush();

      print(
        'MODERATION_INCOMING_OUTBOX_ENQUEUED: '
        'messageId=$messageId',
      );
    } catch (outboxError, outboxStack) {
      print(
        'MODERATION_INCOMING_OUTBOX_ENQUEUE_ERROR: '
        '$outboxError',
      );
      print(
        'MODERATION_INCOMING_OUTBOX_ENQUEUE_STACK: '
        '$outboxStack',
      );
    }

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

  /// Compatibility entry point for existing callers.
  ///
  /// The envelope is decrypted exactly once and then passed to the
  /// already-decrypted processing path.
  Future<Message?> receiveEnvelope({required Uint8List rawEnvelope}) async {
    final decrypted = await decryptEnvelope(rawEnvelope: rawEnvelope);
    return receiveDecryptedEnvelope(decrypted: decrypted);
  }

  Future<void> addReaction(String messageId, String emoji) async {
    await db.reactionDao.add(messageId, localNickname, emoji);
  }

  Future<void> updateChatTtl(String chatId, int ttlSeconds) async {
    await db.chatDao.updateDefaultTtl(chatId, ttlSeconds);
  }

  /// Sends a Sender Key distribution message individually over Signal.
  /// The distribution payload is authenticated by the pairwise Signal session.
  Future<void> _sendGroupDistributionToMember({
    required String groupId,
    required String groupName,
    required String peerName,
    required Uint8List distributionBytes,
  }) async {
    final peerDeviceId = 1;

    await _ensureDirectSession(
      peerName: peerName,
      peerDeviceId: peerDeviceId,
    );

    final payload = Uint8List.fromList(
      utf8.encode(
        'STELLAR_GROUP_DISTRIBUTION_V1:'
        '${jsonEncode({
          'groupId': groupId,
          'groupName': groupName,
          'senderNickname': localNickname,
          'senderDeviceId': 1,
          'distribution': base64Encode(distributionBytes),
        })}',
      ),
    );

    final address = SignalProtocolAddress(peerName, peerDeviceId);
    final encrypted = await sessionManager.encryptForSend(address, payload);

    final token = Uint8List.fromList(
      utf8.encode(_uuid.v4()).take(16).toList(),
    );

    final envelope = Envelope(
      deliveryToken: token,
      recipientRoute: peerName,
      ciphertext: Uint8List.fromList(encrypted.serialize()),
    );

    final encodedEnvelope = envelope.encode();
    final transportId = _uuid.v4();

    // No message row exists for a Sender Key distribution. Use a unique
    // synthetic reference; the callback branches on transport_type before
    // trying to load a message.
    await db.transportOutboxDao.enqueue(
      messageId: 'group-distribution:$groupId:$transportId',
      transportId: transportId,
      transportType: 'group_distribution',
      deliveryToken: token,
      recipientRoute: peerName,
      envelopeBytes: encodedEnvelope,
      createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
    );

    await transportOutbox.flush();
  }

  Future<void> createGroupChat({
    required String chatId,
    required String displayName,
    required List<String> memberNicknames,
    int defaultTtlSec = 3600,
  }) async {
    final name = displayName.trim();
    if (name.isEmpty) throw ArgumentError('Group name is required');

    final members = memberNicknames
        .map((value) => value.trim().replaceFirst(RegExp(r'^@'), ''))
        .where((value) => value.isNotEmpty)
        .toSet();

    if (members.isEmpty) {
      throw ArgumentError('At least one group member is required');
    }

    final existing = await db.chatDao.byId(chatId);
    if (existing != null) throw StateError('Chat already exists: $chatId');

    await db.chatDao.insert(
      chatId: chatId,
      chatType: 'group',
      displayName: name,
      defaultTtlSec: defaultTtlSec,
    );

    try {
      await db.chatDao.addGroupMember(chatId, localNickname, role: 'owner');
      for (final nickname in members) {
        if (nickname.toLowerCase() != localNickname.toLowerCase()) {
          await db.chatDao.addGroupMember(chatId, nickname);
        }
      }
    } catch (_) {
      await db.chatDao.delete(chatId);
      rethrow;
    }

    // Create the local Sender Key only after group membership is persisted.
    final localAddress = SignalProtocolAddress(localNickname, 1);
    final senderKeyName = SenderKeyName(chatId, localAddress);
    final distributionBytes =
        await groupCrypto.createOrRotateSenderKey(senderKeyName);

    // Register metadata in the background. Server/network failures must not
    // block local group creation or encrypted messaging.
    unawaited(
      moderationClient
          .registerGroup(
            groupId: chatId,
            groupName: name,
            nickname: localNickname,
          )
          .catchError((Object _) {}),
    );

    // Distribute independently to every remote member. Do not send the
    // distribution to the local account.
    for (final nickname in members) {
      if (nickname.toLowerCase() == localNickname.toLowerCase()) {
        continue;
      }

      await _sendGroupDistributionToMember(
        groupId: chatId,
        groupName: name,
        peerName: nickname,
        distributionBytes: distributionBytes,
      );
    }
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
