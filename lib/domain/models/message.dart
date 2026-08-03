/// Delivery/read lifecycle of a message, mirrored in the `status` column
/// of the `message` table (core/storage/database.dart).
enum MessageStatus { sending, sent, delivered, read, failed }

class Message {
  const Message({
    required this.messageId,
    required this.chatId,
    required this.senderId,
    required this.bodyPlaintext,
    required this.sentAt,
    required this.expiresAt,
    this.deliveredAt,
    this.readAt,
    this.replyToId,
    this.status = MessageStatus.sending,
    this.reactions = const [],
    this.mediaBlobId,
  });

  final String messageId;
  final String chatId;
  final String senderId;
  final String bodyPlaintext;
  final DateTime sentAt;
  final DateTime expiresAt;
  final DateTime? deliveredAt;
  final DateTime? readAt;
  final String? replyToId;
  final MessageStatus status;
  final List<Reaction> reactions;
  final String? mediaBlobId;

  Duration get timeUntilExpiry => expiresAt.difference(DateTime.now());
  bool get isExpired => timeUntilExpiry.isNegative;

  Message copyWith({
    MessageStatus? status,
    DateTime? deliveredAt,
    DateTime? readAt,
    List<Reaction>? reactions,
  }) {
    return Message(
      messageId: messageId,
      chatId: chatId,
      senderId: senderId,
      bodyPlaintext: bodyPlaintext,
      sentAt: sentAt,
      expiresAt: expiresAt,
      deliveredAt: deliveredAt ?? this.deliveredAt,
      readAt: readAt ?? this.readAt,
      replyToId: replyToId,
      status: status ?? this.status,
      reactions: reactions ?? this.reactions,
      mediaBlobId: mediaBlobId,
    );
  }

  factory Message.fromRow(Map<String, Object?> row) {
    return Message(
      messageId: row['message_id'] as String,
      chatId: row['chat_id'] as String,
      senderId: row['sender_id'] as String,
      bodyPlaintext: row['body_plaintext'] as String? ?? '',
      sentAt: DateTime.fromMillisecondsSinceEpoch((row['sent_at'] as int) * 1000),
      expiresAt: DateTime.fromMillisecondsSinceEpoch((row['expires_at'] as int) * 1000),
      deliveredAt: row['delivered_at'] == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch((row['delivered_at'] as int) * 1000),
      readAt: row['read_at'] == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch((row['read_at'] as int) * 1000),
      replyToId: row['reply_to_id'] as String?,
      status: MessageStatus.values.firstWhere(
        (s) => s.name == row['status'],
        orElse: () => MessageStatus.sent,
      ),
    );
  }
}

class Reaction {
  const Reaction({required this.messageId, required this.senderId, required this.emoji});
  final String messageId;
  final String senderId;
  final String emoji;
}
