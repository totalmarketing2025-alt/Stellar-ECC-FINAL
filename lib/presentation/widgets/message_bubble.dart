import 'package:flutter/material.dart';

import '../../core/theme/stellar_theme.dart';
import '../../domain/models/message.dart';
import 'expiry_ring.dart';

class MessageBubble extends StatelessWidget {
  const MessageBubble({
    super.key,
    required this.message,
    required this.isOutgoing,
    required this.onReply,
    required this.onReact,
  });

  final Message message;
  final bool isOutgoing;
  final VoidCallback onReply;
  final void Function(String emoji) onReact;

  static const _quickReactions = ['❤️', '😂', '👍', '😮', '😢', '🙏'];

  @override
  Widget build(BuildContext context) {
    final alignment = isOutgoing ? CrossAxisAlignment.end : CrossAxisAlignment.start;
    final bubbleColor = isOutgoing ? StellarColors.accentBlue.withOpacity(0.18) : StellarColors.bgSurface;
    final borderColor = isOutgoing ? StellarColors.accentBlue : Colors.transparent;

    return Dismissible(
      key: ValueKey(message.messageId),
      direction: DismissDirection.startToEnd,
      confirmDismiss: (_) async {
        onReply();
        return false; // never actually remove the tile — reply is a side effect
      },
      background: const Padding(
        padding: EdgeInsets.symmetric(horizontal: 16),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Icon(Icons.reply, color: StellarColors.accentBlue),
        ),
      ),
      child: GestureDetector(
        onLongPress: () => _showReactionTray(context),
        child: Column(
          crossAxisAlignment: alignment,
          children: [
            Container(
              margin: const EdgeInsets.symmetric(vertical: 4),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
              decoration: BoxDecoration(
                color: bubbleColor,
                border: Border.all(color: borderColor),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (!isOutgoing)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 2),
                      child: Text(message.senderId,
                          style: const TextStyle(fontSize: 11, color: StellarColors.accentPurple, fontWeight: FontWeight.w600)),
                    ),
                  Text(message.bodyPlaintext, style: const TextStyle(fontSize: 15)),
                  const SizedBox(height: 4),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(_formatTime(message.sentAt),
                          style: const TextStyle(fontSize: 10, color: StellarColors.textSecondary)),
                      const SizedBox(width: 6),
                      ExpiryRing(expiresAt: message.expiresAt, size: 12),
                      if (isOutgoing) ...[
                        const SizedBox(width: 6),
                        _StatusTicks(status: message.status),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            if (message.reactions.isNotEmpty)
              Wrap(
                spacing: 4,
                children: message.reactions
                    .map((r) => Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: StellarColors.bgElevated,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(r.emoji, style: const TextStyle(fontSize: 12)),
                        ))
                    .toList(),
              ),
          ],
        ),
      ),
    );
  }

  void _showReactionTray(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: StellarColors.bgElevated,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Wrap(
            spacing: 16,
            children: _quickReactions
                .map((emoji) => GestureDetector(
                      onTap: () {
                        onReact(emoji);
                        Navigator.pop(sheetContext);
                      },
                      child: Text(emoji, style: const TextStyle(fontSize: 28)),
                    ))
                .toList(),
          ),
        ),
      ),
    );
  }

  String _formatTime(DateTime dt) {
    final hour = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final minute = dt.minute.toString().padLeft(2, '0');
    final period = dt.hour >= 12 ? 'PM' : 'AM';
    return '$hour:$minute $period';
  }
}

class _StatusTicks extends StatelessWidget {
  const _StatusTicks({required this.status});
  final MessageStatus status;

  @override
  Widget build(BuildContext context) {
    IconData icon;
    Color color = StellarColors.textSecondary;
    switch (status) {
      case MessageStatus.sending:
        icon = Icons.schedule;
        break;
      case MessageStatus.sent:
        icon = Icons.check;
        break;
      case MessageStatus.delivered:
        icon = Icons.done_all;
        break;
      case MessageStatus.read:
        icon = Icons.done_all;
        color = StellarColors.success;
        break;
      case MessageStatus.failed:
        icon = Icons.error_outline;
        color = StellarColors.danger;
        break;
    }
    return Icon(icon, size: 12, color: color);
  }
}
