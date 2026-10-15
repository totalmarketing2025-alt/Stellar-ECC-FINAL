import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';

import '../../core/theme/stellar_theme.dart';
import '../../domain/models/message.dart';
import 'expiry_ring.dart';


class _AudioAttachmentPlayer extends StatefulWidget {
  const _AudioAttachmentPlayer({required this.bytesFuture});

  final Future<Uint8List> bytesFuture;

  @override
  State<_AudioAttachmentPlayer> createState() =>
      _AudioAttachmentPlayerState();
}

class _AudioAttachmentPlayerState extends State<_AudioAttachmentPlayer> {
  late final AudioPlayer _player;

  @override
  void initState() {
    super.initState();
    _player = AudioPlayer();
    _player.setReleaseMode(ReleaseMode.stop);
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  Future<void> _toggle(Uint8List bytes, PlayerState state) async {
    try {
      if (state == PlayerState.playing) {
        await _player.pause();
      } else if (state == PlayerState.paused) {
        await _player.resume();
      } else {
        await _player.play(
          BytesSource(bytes, mimeType: 'audio/mp4'),
        );
      }
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Unable to play voice message')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List>(
      future: widget.bytesFuture,
      builder: (context, bytesSnapshot) {
        if (bytesSnapshot.connectionState == ConnectionState.waiting) {
          return const SizedBox(
            width: 44,
            height: 44,
            child: Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        }

        if (!bytesSnapshot.hasData) {
          return const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.broken_image, size: 22),
              SizedBox(width: 6),
              Text('Audio unavailable'),
            ],
          );
        }

        final bytes = bytesSnapshot.data!;

        return StreamBuilder<PlayerState>(
          stream: _player.onPlayerStateChanged,
          initialData: PlayerState.stopped,
          builder: (context, stateSnapshot) {
            final state = stateSnapshot.data ?? PlayerState.stopped;
            final playing = state == PlayerState.playing;

            return Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: playing ? 'Pause voice message' : 'Play voice message',
                  onPressed: () => _toggle(bytes, state),
                  icon: Icon(
                    playing ? Icons.pause_circle_filled : Icons.play_circle_fill,
                    size: 32,
                  ),
                ),
                const Flexible(
                  child: Text(
                    'Voice message',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

class _AttachmentPreview extends StatefulWidget {
  const _AttachmentPreview({
    required this.blobId,
    required this.mimeType,
    required this.onLoadAttachment,
  });

  final String blobId;
  final String? mimeType;
  final Future<Uint8List> Function(String blobId) onLoadAttachment;

  @override
  State<_AttachmentPreview> createState() => _AttachmentPreviewState();
}

class _AttachmentPreviewState extends State<_AttachmentPreview> {
  late Future<Uint8List> _attachmentFuture;

  @override
  void initState() {
    super.initState();
    _attachmentFuture = widget.onLoadAttachment(widget.blobId);
  }

  bool get _isImage =>
      widget.mimeType?.toLowerCase().startsWith('image/') == true;

  bool get _isAudio =>
      widget.mimeType?.toLowerCase().startsWith('audio/') == true;

  String _extensionForMime(String? mimeType) {
    switch (mimeType?.toLowerCase()) {
      case 'image/jpeg':
        return 'jpg';
      case 'image/png':
        return 'png';
      case 'image/gif':
        return 'gif';
      case 'image/webp':
        return 'webp';
      case 'image/heic':
        return 'heic';
      case 'image/heif':
        return 'heif';
      case 'audio/mp4':
        return 'm4a';
      case 'video/mp4':
        return 'mp4';
      case 'video/quicktime':
        return 'mov';
      case 'application/pdf':
        return 'pdf';
      default:
        return 'bin';
    }
  }

  Future<void> _saveAttachment(BuildContext context) async {
    final bytes = await widget.onLoadAttachment(widget.blobId);
    if (!context.mounted) return;

    final extension = _extensionForMime(widget.mimeType);
    final fileName = 'attachment_${widget.blobId}.$extension';

    await FilePicker.platform.saveFile(
      dialogTitle: 'Save attachment',
      fileName: fileName,
      bytes: bytes,
    );
  }

  Widget _saveButton(BuildContext context) {
    return IconButton(
      tooltip: 'Save attachment',
      icon: const Icon(Icons.download),
      onPressed: () async {
        try {
          await _saveAttachment(context);
        } catch (_) {
          if (!context.mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Unable to save attachment'),
            ),
          );
        }
      },
    );
  }

  @override
  void didUpdateWidget(covariant _AttachmentPreview oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.blobId != widget.blobId ||
        oldWidget.mimeType != widget.mimeType) {
      _attachmentFuture = widget.onLoadAttachment(widget.blobId);
    }
  }

  @override
  Widget build(BuildContext context) {

    if (_isAudio) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: _AudioAttachmentPlayer(
                bytesFuture: _attachmentFuture,
              ),
            ),
            _saveButton(context),
          ],
        ),
      );
    }

    if (!_isImage) {
      final mime = widget.mimeType?.toLowerCase();

      final IconData icon;
      final String label;

      if (mime == 'application/pdf') {
        icon = Icons.picture_as_pdf;
        label = 'PDF attachment';
      } else if (mime?.startsWith('video/') == true) {
        icon = Icons.videocam;
        label = 'Video attachment';
      } else {
        icon = Icons.attach_file;
        label = 'File attachment';
      }

      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 28),
            const SizedBox(width: 10),
            Text(label),
            _saveButton(context),
          ],
        ),
      );
    }

    return FutureBuilder<Uint8List>(
      future: _attachmentFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const SizedBox(
            width: 180,
            height: 120,
            child: Center(
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          );
        }

        if (snapshot.hasData) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.memory(
                  snapshot.data!,
                  width: 180,
                  height: 180,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.broken_image, size: 22),
                        SizedBox(width: 8),
                        Text('Attachment unavailable'),
                      ],
                    ),
                  ),
                ),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: _saveButton(context),
              ),
            ],
          );
        }

        return const Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.broken_image, size: 22),
              SizedBox(width: 8),
              Text('Attachment unavailable'),
            ],
          ),
        );
      },
    );
  }
}

class MessageBubble extends StatelessWidget {
  const MessageBubble({
    super.key,
    required this.message,
    required this.isOutgoing,
    required this.onReply,
    required this.onReact,
    required this.onDelete,
    required this.onLoadAttachment,
  });

  final Message message;
  final bool isOutgoing;
  final VoidCallback onReply;
  final void Function(String emoji) onReact;
  final VoidCallback onDelete;
  final Future<Uint8List> Function(String blobId) onLoadAttachment;

  static const _quickReactions = ['❤️', '😂', '👍', '😮', '😢', '🙏'];

  @override
  Widget build(BuildContext context) {
    final alignment = isOutgoing ? CrossAxisAlignment.start : CrossAxisAlignment.end;
    final bubbleAlignment = isOutgoing ? Alignment.centerLeft : Alignment.centerRight;
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
            Align(
              alignment: bubbleAlignment,
              child: Container(
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
                  if (message.mediaBlobId != null)
                    _AttachmentPreview(
                      blobId: message.mediaBlobId!,
                      mimeType: message.mediaMimeType,
                      onLoadAttachment: onLoadAttachment,
                    )
                  else
                    Text(
                      message.bodyPlaintext,
                      style: const TextStyle(fontSize: 15),
                    ),
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
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Wrap(
                spacing: 16,
                children: _quickReactions
                    .map(
                      (emoji) => GestureDetector(
                        onTap: () {
                          onReact(emoji);
                          Navigator.pop(sheetContext);
                        },
                        child: Text(
                          emoji,
                          style: const TextStyle(fontSize: 28),
                        ),
                      ),
                    )
                    .toList(),
              ),
              const SizedBox(height: 12),
              const Divider(),
              ListTile(
                leading: const Icon(
                  Icons.delete_outline,
                  color: StellarColors.danger,
                ),
                title: const Text('Delete message'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  onDelete();
                },
              ),
            ],
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
