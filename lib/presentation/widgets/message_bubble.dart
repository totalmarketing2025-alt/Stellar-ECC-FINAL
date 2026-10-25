import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';

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


void _openImageFullscreen(BuildContext context, Uint8List bytes) {
  showDialog<void>(
    context: context,
    barrierColor: Colors.black,
    builder: (dialogContext) {
      return Dialog.fullscreen(
        backgroundColor: Colors.black,
        child: Stack(
          children: [
            Positioned.fill(
              child: InteractiveViewer(
                minScale: 0.5,
                maxScale: 5.0,
                child: Center(
                  child: Image.memory(
                    bytes,
                    fit: BoxFit.contain,
                    errorBuilder: (_, __, ___) => const Icon(
                      Icons.broken_image,
                      color: Colors.white,
                      size: 48,
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              top: 12,
              right: 12,
              child: SafeArea(
                child: IconButton(
                  tooltip: 'Close image',
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  icon: const Icon(
                    Icons.close,
                    color: Colors.white,
                    size: 30,
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    },
  );
}


class _VideoAttachmentPlayer extends StatefulWidget {
  const _VideoAttachmentPlayer({
    required this.bytesFuture,
    required this.extension,
  });

  final Future<Uint8List> bytesFuture;
  final String extension;

  @override
  State<_VideoAttachmentPlayer> createState() =>
      _VideoAttachmentPlayerState();
}

class _VideoAttachmentPlayerState extends State<_VideoAttachmentPlayer> {
  VideoPlayerController? _controller;
  Future<void>? _initializeFuture;
  File? _tempFile;
  bool _failed = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _initializeVideo();
  }

  @override
  void didUpdateWidget(covariant _VideoAttachmentPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.bytesFuture != widget.bytesFuture ||
        oldWidget.extension != widget.extension) {
      _generation++;
      final oldController = _controller;
      _controller = null;
      _initializeFuture = null;
      _failed = false;
      oldController?.dispose();

      final oldFile = _tempFile;
      _tempFile = null;
      if (oldFile != null) {
        oldFile.delete().catchError((Object _) => oldFile);
      }
      _initializeVideo();
    }
  }

  Future<void> _initializeVideo() async {
    final generation = ++_generation;

    try {
      final bytes = await widget.bytesFuture;
      if (!mounted || generation != _generation) return;

      final directory = await getTemporaryDirectory();
      final file = File(
        '${directory.path}/stellar_video_'
        '${DateTime.now().microsecondsSinceEpoch}.${widget.extension}',
      );
      await file.writeAsBytes(bytes, flush: true);

      if (!mounted || generation != _generation) {
        await file.delete().catchError((Object _) => file);
        return;
      }

      final controller = VideoPlayerController.file(file);
      _tempFile = file;
      _controller = controller;
      final initialization = controller.initialize();
      _initializeFuture = initialization;

      await initialization;
      if (!mounted || generation != _generation) return;

      await controller.setLooping(false);
      if (mounted && generation == _generation) setState(() {});
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(() => _failed = true);
      }
    }
  }

  @override
  void dispose() {
    _generation++;
    _controller?.dispose();
    final file = _tempFile;
    if (file != null) {
      file.delete().catchError((Object _) => file);
    }
    super.dispose();
  }

  Future<void> _togglePlayback() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;

    if (controller.value.isPlaying) {
      await controller.pause();
    } else {
      await controller.play();
    }
  }

  Widget _placeholder() {
    return SizedBox(
      width: 240,
      height: 135,
      child: Center(
        child: _failed
            ? const Text('Unable to load video')
            : const CircularProgressIndicator(strokeWidth: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final initialization = _initializeFuture;

    if (_failed || controller == null || initialization == null) {
      return _placeholder();
    }

    return FutureBuilder<void>(
      future: initialization,
      builder: (context, snapshot) {
        if (snapshot.hasError) return _placeholder();
        if (snapshot.connectionState != ConnectionState.done ||
            !controller.value.isInitialized) {
          return _placeholder();
        }

        final ratio = controller.value.aspectRatio > 0
            ? controller.value.aspectRatio
            : 16 / 9;

        return ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 280),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: ColoredBox(
              color: Colors.black,
              child: ValueListenableBuilder<VideoPlayerValue>(
                valueListenable: controller,
                builder: (context, value, child) {
                  final maxMs =
                      value.duration.inMilliseconds.clamp(1, 2147483647);
                  final currentMs =
                      value.position.inMilliseconds.clamp(0, maxMs);

                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AspectRatio(
                        aspectRatio: ratio,
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            VideoPlayer(controller),
                            IconButton(
                              tooltip:
                                  value.isPlaying ? 'Pause video' : 'Play video',
                              onPressed: _togglePlayback,
                              iconSize: 48,
                              color: Colors.white,
                              icon: Icon(
                                value.isPlaying
                                    ? Icons.pause_circle_filled
                                    : Icons.play_circle_fill,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Row(
                        children: [
                          IconButton(
                            visualDensity: VisualDensity.compact,
                            tooltip:
                                value.isPlaying ? 'Pause video' : 'Play video',
                            onPressed: _togglePlayback,
                            icon: Icon(
                              value.isPlaying ? Icons.pause : Icons.play_arrow,
                            ),
                          ),
                          Expanded(
                            child: Slider(
                              min: 0,
                              max: maxMs.toDouble(),
                              value: currentMs.toDouble(),
                              onChanged: (milliseconds) {
                                controller.seekTo(
                                  Duration(
                                    milliseconds: milliseconds.round(),
                                  ),
                                );
                              },
                            ),
                          ),
                        ],
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
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

  bool get _isVideo =>
      widget.mimeType?.toLowerCase().startsWith('video/') == true;

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


    if (_isVideo) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: _VideoAttachmentPlayer(
                bytesFuture: _attachmentFuture,
                extension: _extensionForMime(widget.mimeType),
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
              GestureDetector(
                onTap: () => _openImageFullscreen(context, snapshot.data!),
                child: ClipRRect(
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
    final alignment = isOutgoing ? CrossAxisAlignment.end : CrossAxisAlignment.start;
    final bubbleAlignment = isOutgoing ? Alignment.centerRight : Alignment.centerLeft;
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
