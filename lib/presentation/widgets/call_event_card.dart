import 'package:flutter/material.dart';

import '../../core/theme/stellar_theme.dart';
import '../../domain/models/call_event.dart';
import '../../domain/models/message.dart';

/// One timeline card for all encrypted history events belonging to a call.
class CallEventCard extends StatelessWidget {
  const CallEventCard({
    super.key,
    required this.events,
    required this.localNickname,
  });

  final List<Message> events;
  final String localNickname;

  static int _outcomeRank(String? outcome) {
    switch (outcome) {
      case 'completed':
        return 5;
      case 'declined':
        return 4;
      case 'no_answer':
        return 3;
      case 'cancelled':
        return 2;
      case 'failed':
        return 1;
      default:
        return 0;
    }
  }

  static String _durationLabel(int seconds) {
    final minutes = seconds ~/ 60;
    final remaining = seconds % 60;
    if (minutes == 0) return '${remaining}s';
    if (remaining == 0) return '${minutes}m';
    return '${minutes}m ${remaining}s';
  }

  static String _timeLabel(DateTime value) {
    final hour = value.hour % 12 == 0 ? 12 : value.hour % 12;
    final minute = value.minute.toString().padLeft(2, '0');
    return '$hour:$minute ${value.hour >= 12 ? 'PM' : 'AM'}';
  }

  @override
  Widget build(BuildContext context) {
    Message? startedMessage;
    CallEventPayload? started;
    CallEventPayload? terminal;

    for (final message in events) {
      final event = CallEventPayload.tryParse(message.bodyPlaintext);
      if (event == null) continue;

      if (event.phase == 'started') {
        if (startedMessage == null ||
            message.sentAt.isBefore(startedMessage.sentAt)) {
          startedMessage = message;
          started = event;
        }
      } else if (terminal == null ||
          _outcomeRank(event.outcome) > _outcomeRank(terminal.outcome) ||
          (_outcomeRank(event.outcome) == _outcomeRank(terminal.outcome) &&
              (event.durationSeconds ?? 0) >
                  (terminal.durationSeconds ?? 0))) {
        terminal = event;
      }
    }

    final event = started ?? terminal;
    if (event == null) return const SizedBox.shrink();

    final outgoing = startedMessage != null &&
        startedMessage.senderId.toLowerCase() ==
            localNickname.toLowerCase();

    final video = event.kind == 'video';
    final title =
        '${outgoing ? 'Outgoing' : 'Incoming'} ${video ? 'video' : 'voice'} call';

    String subtitle;
    switch (terminal?.outcome) {
      case 'completed':
        final duration = terminal?.durationSeconds;
        subtitle = duration == null
            ? 'Completed'
            : 'Completed · ${_durationLabel(duration)}';
        break;
      case 'declined':
        subtitle = 'Declined';
        break;
      case 'no_answer':
        subtitle = 'No answer';
        break;
      case 'cancelled':
        subtitle = 'Cancelled';
        break;
      case 'failed':
        subtitle = 'Failed';
        break;
      default:
        subtitle = outgoing ? 'Calling…' : 'Incoming call';
    }

    final timestamp = startedMessage?.sentAt ??
        events.map((m) => m.sentAt).reduce(
              (a, b) => a.isBefore(b) ? a : b,
            );

    final iconColor = terminal?.outcome == 'failed'
        ? StellarColors.danger
        : terminal?.outcome == 'completed'
            ? StellarColors.success
            : StellarColors.accentBlue;

    return Align(
      alignment: outgoing ? Alignment.centerLeft : Alignment.centerRight,
      child: Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.82,
        ),
        margin: const EdgeInsets.symmetric(vertical: 5),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: StellarColors.bgSurface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: iconColor.withOpacity(0.55),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: iconColor.withOpacity(0.14),
                shape: BoxShape.circle,
              ),
              child: Icon(
                video ? Icons.videocam_outlined : Icons.call_outlined,
                color: iconColor,
              ),
            ),
            const SizedBox(width: 12),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      fontSize: 13,
                      color: StellarColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _timeLabel(timestamp),
                    style: const TextStyle(
                      fontSize: 10,
                      color: StellarColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
