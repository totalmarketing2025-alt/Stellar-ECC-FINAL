class ModerationAdminMessage {
  const ModerationAdminMessage({
    required this.messageId,
    required this.sender,
    required this.recipient,
    required this.createdAt,
    required this.expiresAt,
    required this.contentType,
    required this.plaintext,
    this.chatId,
    this.attachmentMimeType,
  });

  final String messageId;
  final String sender;
  final String recipient;
  final String? chatId;
  final int createdAt;
  final int expiresAt;
  final String contentType;
  final String plaintext;
  final String? attachmentMimeType;

  factory ModerationAdminMessage.fromJson(Map<String, dynamic> json) {
    return ModerationAdminMessage(
      messageId: json["message_id"] as String? ?? "",
      sender: json["sender"] as String? ?? "",
      recipient: json["recipient"] as String? ?? "",
      chatId: json["chat_id"] as String?,
      createdAt: (json["created_at"] as num?)?.toInt() ?? 0,
      expiresAt: (json["expires_at"] as num?)?.toInt() ?? 0,
      contentType: json["content_type"] as String? ?? "text/plain",
      plaintext: json["plaintext"] as String? ?? "",
      attachmentMimeType: json["attachment_mime_type"] as String?,
    );
  }
}
