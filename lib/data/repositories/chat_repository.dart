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
  final _uuid = const Uuid();

  Future<List<Chat>> loadChats() async {
    final rows = await db.chatDao.all();
    return rows.map(Chat.fromRow).toList();
  }

  Future<List<Message>> loadMessages(String chatId) async {
    final rows = await db.messageDao.forChat(chatId);
    return rows.map(Message.fromRow).toList();
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
      _knownDirectPeersWithSessions() async {
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

      final address = SignalProtocolAddress(peerName, peerDeviceId);
      if (await sessionManager.hasSession(address)) {
        result.add((
          chatId: chatId,
          peerName: peerName,
          peerDeviceId: peerDeviceId,
        ));
      }
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
  }) async {
    final address = SignalProtocolAddress(
      peerName,
      peerDeviceId,
    );

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
  }) async {
    final chatRow = await db.chatDao.byId(chatId);
    final peerName = chatRow?['peer_name'] as String?;
    final peerDeviceId = chatRow?['peer_device_id'] as int?;

    if (peerName == null || peerName.isEmpty || peerDeviceId == null) {
      throw StateError('Direct chat peer mapping is missing for $chatId');
    }

    final messageId = _uuid.v4();

    // 1. Persist locally immediately (optimistic UI), status = sending.
    await db.messageDao.insert(
      messageId: messageId,
      chatId: chatId,
      senderId: localNickname,
      plaintext: plaintext,
      ttlSeconds: ttlSeconds,
      replyToId: replyToId,
    );

    if (attachmentBytes != null && attachmentMimeType != null && mediaService != null) {
      await mediaService!.storeAttachment(
        rawBytes: attachmentBytes,
        messageId: messageId,
        mimeType: attachmentMimeType,
        ttlSeconds: ttlSeconds,
      );
    }

    // 2. Encrypt via the Double Ratchet session with the recipient.
    await _ensureDirectSession(
      peerName: peerName,
      peerDeviceId: peerDeviceId,
    );

    final address = SignalProtocolAddress(peerName, peerDeviceId);
    final plaintextBytes = Uint8List.fromList(utf8.encode(plaintext));
    final ciphertextMessage = await sessionManager.encryptForSend(address, plaintextBytes);

    // 3. Wrap in the relay envelope. The delivery token is a fresh random
    // id per send — never the sender's static identity (sealed sender,
    // Phase 4 §2) — the relay only learns a rotating token and the
    // recipient's route.
    final token = Uint8List.fromList(utf8.encode(_uuid.v4()).take(16).toList());
    final envelope = Envelope(
      deliveryToken: token,
      recipientRoute: peerName, // resolved server-side to an opaque route in production
      ciphertext: Uint8List.fromList(ciphertextMessage.serialize()),
    );

    try {
      await relayClient.send(envelope.encode());
      await db.messageDao.updateStatus(messageId, 'sent');
    } catch (_) {
      await db.messageDao.updateStatus(messageId, 'failed');
    }

    final rows = await db.messageDao.forChat(chatId);
    return rows.map(Message.fromRow).firstWhere((m) => m.messageId == messageId);
  }

  /// Handles an inbound envelope already routed to this chat by the
  /// caller (see presentation/state/relay_listener.dart in the next
  /// module, which demultiplexes incoming envelopes by sender before
  /// calling this).
  Future<Message> receiveEnvelope({
    required Uint8List rawEnvelope,
  }) async {
    final envelope = Envelope.decode(rawEnvelope);

    final peers = await _knownDirectPeersWithSessions();
    if (peers.isEmpty) {
      throw StateError('No known direct peer session can receive this envelope');
    }

    late final String chatId;
    late final String senderNickname;
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

    final plaintext = utf8.decode(plaintextBytes);
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

    final rows = await db.messageDao.forChat(chatId);
    return rows
        .map(Message.fromRow)
        .firstWhere((m) => m.messageId == messageId);
  }

  Future<void> deleteChatNow(String chatId) => db.chatDao.delete(chatId);

  Future<void> updateChatTtl(String chatId, int ttlSeconds) =>
      db.chatDao.updateDefaultTtl(chatId, ttlSeconds);

  Future<void> addReaction(String messageId, String emoji) =>
      db.reactionDao.add(messageId, localNickname, emoji);

  Future<void> createDirectChat({
    required String chatId,
    required String displayName,
    int defaultTtlSeconds = TtlPreset.oneHour,
    String? peerName,
    int? peerDeviceId,
  }) {
    return db.chatDao.insert(
      chatId: chatId,
      chatType: 'direct',
      displayName: displayName,
      defaultTtlSec: defaultTtlSeconds,
      peerName: peerName,
      peerDeviceId: peerDeviceId,
    );
  }
}
