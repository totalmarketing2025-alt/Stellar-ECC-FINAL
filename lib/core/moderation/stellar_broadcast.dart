class StellarBroadcast {
  const StellarBroadcast({
    required this.broadcastId,
    required this.title,
    required this.message,
    required this.createdAt,
    required this.createdBy,
    this.attachmentMimeType,
    this.attachmentSize,
  });

  final String broadcastId;
  final String title;
  final String message;
  final int createdAt;
  final String createdBy;
  final String? attachmentMimeType;
  final int? attachmentSize;

  bool get hasAttachment =>
      attachmentMimeType != null &&
      attachmentMimeType!.isNotEmpty;

  DateTime get createdAtDate =>
      DateTime.fromMillisecondsSinceEpoch(createdAt);

  factory StellarBroadcast.fromJson(Map<String, dynamic> json) {
    final id = json['broadcast_id'];
    final title = json['title'];
    final message = json['message'];
    final createdAt = json['created_at'];
    final createdBy = json['created_by'];
    final mimeType = json['attachment_mime_type'];
    final attachmentSize = json['attachment_size'];

    if (id is! String ||
        title is! String ||
        message is! String ||
        createdAt is! num ||
        createdBy is! String) {
      throw const FormatException(
        'Invalid Stellar Broadcast response',
      );
    }

    if (mimeType != null && mimeType is! String) {
      throw const FormatException(
        'Invalid Broadcast attachment MIME type',
      );
    }

    if (attachmentSize != null && attachmentSize is! num) {
      throw const FormatException(
        'Invalid Broadcast attachment size',
      );
    }

    return StellarBroadcast(
      broadcastId: id,
      title: title,
      message: message,
      createdAt: createdAt.toInt(),
      createdBy: createdBy,
      attachmentMimeType: mimeType as String?,
      attachmentSize: (attachmentSize as num?)?.toInt(),
    );
  }
}
