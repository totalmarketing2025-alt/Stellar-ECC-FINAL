enum ChatType { direct, group }

class Chat {
  const Chat({
    required this.chatId,
    required this.chatType,
    required this.displayName,
    required this.defaultTtlSeconds,
    required this.createdAt,
    this.lastMessagePreview,
    this.lastMessageAt,
    this.unreadCount = 0,
    this.oldestVisibleExpiry,
    this.memberIds = const [],
    this.peerName,
    this.peerDeviceId,
  });

  final String chatId;
  final ChatType chatType;
  final String displayName;
  final int defaultTtlSeconds;
  final DateTime createdAt;
  final String? lastMessagePreview;
  final DateTime? lastMessageAt;
  final int unreadCount;
  final DateTime? oldestVisibleExpiry;
  final List<String> memberIds;
  final String? peerName;
  final int? peerDeviceId;

  factory Chat.fromRow(Map<String, Object?> row) {
    return Chat(
      chatId: row['chat_id'] as String,
      chatType: (row['chat_type'] as String) == 'group' ? ChatType.group : ChatType.direct,
      displayName: row['display_name'] as String,
      defaultTtlSeconds: row['default_ttl_sec'] as int,
      createdAt: DateTime.fromMillisecondsSinceEpoch((row['created_at'] as int) * 1000),
      peerName: row['peer_name'] as String?,
      peerDeviceId: row['peer_device_id'] as int?,
    );
  }

  Chat copyWith({
    String? lastMessagePreview,
    DateTime? lastMessageAt,
    int? unreadCount,
    DateTime? oldestVisibleExpiry,
  }) {
    return Chat(
      chatId: chatId,
      chatType: chatType,
      displayName: displayName,
      defaultTtlSeconds: defaultTtlSeconds,
      createdAt: createdAt,
      lastMessagePreview: lastMessagePreview ?? this.lastMessagePreview,
      lastMessageAt: lastMessageAt ?? this.lastMessageAt,
      unreadCount: unreadCount ?? this.unreadCount,
      oldestVisibleExpiry: oldestVisibleExpiry ?? this.oldestVisibleExpiry,
      memberIds: memberIds,
    );
  }
}

/// Common TTL presets surfaced in the composer/settings UI (Phase 5).
class TtlPreset {
  static const off = 0;
  static const thirtySeconds = 30;
  static const fiveMinutes = 5 * 60;
  static const oneHour = 60 * 60;
  static const oneDay = 24 * 60 * 60;
  static const oneWeek = 7 * 24 * 60 * 60;

  static const all = [off, thirtySeconds, fiveMinutes, oneHour, oneDay, oneWeek];

  static String label(int seconds) {
    switch (seconds) {
      case off:
        return 'Off';
      case thirtySeconds:
        return '30 seconds';
      case fiveMinutes:
        return '5 minutes';
      case oneHour:
        return '1 hour';
      case oneDay:
        return '1 day';
      case oneWeek:
        return '1 week';
      default:
        return '${seconds}s';
    }
  }
}
