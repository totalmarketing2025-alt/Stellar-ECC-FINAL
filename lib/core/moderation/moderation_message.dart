import 'dart:typed_data';

/// Server-side moderation copy of a message.
///
/// This model intentionally lives outside the Signal/Relay layer.
/// The normal chat message remains end-to-end encrypted through Signal.
///
/// MOD-1A only defines the transport contract.
/// Network transmission is added separately in MOD-1B.
class ModerationMessage {
  const ModerationMessage({
    required this.messageId,
    required this.sender,
    required this.recipient,
    required this.createdAt,
    required this.contentType,
    required this.plaintext,
    this.chatId,
    this.attachmentMimeType,
    this.attachmentBytes,
  });

  final String messageId;
  final String sender;
  final String recipient;
  final String? chatId;
  final int createdAt;
  final String contentType;
  final String plaintext;
  final String? attachmentMimeType;
  final Uint8List? attachmentBytes;

  Map<String, dynamic> toJson() {
    return {
      'messageId': messageId,
      'sender': sender,
      'recipient': recipient,
      if (chatId != null) 'chatId': chatId,
      'createdAt': createdAt,
      'contentType': contentType,
      'plaintext': plaintext,
      if (attachmentMimeType != null)
        'attachmentMimeType': attachmentMimeType,
    };
  }
}
