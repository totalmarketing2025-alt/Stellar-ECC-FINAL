import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/stellar_theme.dart';
import '../../../domain/models/message.dart';
import '../../../domain/models/chat.dart';
import '../../state/app_providers.dart';
import '../../widgets/stellar_avatar.dart';
import '../../widgets/expiry_ring.dart';
import '../../widgets/message_bubble.dart';
import '../../widgets/ttl_picker_sheet.dart';
import '../../widgets/attachment_picker_sheet.dart';

class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key, required this.chatId});
  final String chatId;

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final _composerController = TextEditingController();
  final _scrollController = ScrollController();
  Timer? _refreshTimer;
  Message? _replyingTo;
  int _perMessageTtlOverride = -1; // -1 = use chat default

  @override
  void initState() {
    super.initState();
    _refreshTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      ref.invalidate(chatMessagesProvider(widget.chatId));
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _composerController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final messagesAsync = ref.watch(chatMessagesProvider(widget.chatId));
    final chatsAsync = ref.watch(chatListProvider);
    final chat = chatsAsync.maybeWhen(
      data: (chats) => chats.where((c) => c.chatId == widget.chatId).cast<Chat?>().firstOrNull,
      orElse: () => null,
    );

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Row(
          children: [
            StellarAvatar(seed: widget.chatId, label: chat?.displayName ?? '?', size: 36),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                chat?.displayName ?? widget.chatId,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.call_outlined),
            onPressed: () => context.push('/call/voice/${widget.chatId}'),
          ),
          IconButton(
            icon: const Icon(Icons.videocam_outlined),
            onPressed: () => context.push('/call/video/${widget.chatId}'),
          ),
        ],
      ),
      body: Column(
        children: [
          _DisappearingBanner(
            ttlSeconds: chat?.defaultTtlSeconds ?? TtlPreset.oneHour,
            onTap: () => _showChatTtlPicker(chat),
          ),
          Expanded(
            child: messagesAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (err, st) => Center(
                child: Text('Failed to load messages: $err',
                    style: const TextStyle(color: StellarColors.danger)),
              ),
              data: (messages) {
                if (messages.isEmpty) {
                  return const Center(
                    child: Text('No messages yet — say hello 👋',
                        style: TextStyle(color: StellarColors.textSecondary)),
                  );
                }
                return ListView.builder(
                  controller: _scrollController,
                  reverse: true,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  itemCount: messages.length,
                  itemBuilder: (context, index) {
                    final message = messages[messages.length - 1 - index];
                    final localNickname = ref.read(localNicknameProvider);
                    return MessageBubble(
                      message: message,
                      isOutgoing: message.senderId == localNickname,
                      onReply: () => setState(() => _replyingTo = message),
                      onReact: (emoji) =>
                          ref.read(chatRepositoryProvider).addReaction(message.messageId, emoji),
                    );
                  },
                );
              },
            ),
          ),
          if (_replyingTo != null) _ReplyPreview(
            message: _replyingTo!,
            onCancel: () => setState(() => _replyingTo = null),
          ),
          _Composer(
            controller: _composerController,
            onSend: _handleSend,
            onPickTtl: () => _showComposerTtlPicker(chat),
            onAttach: _handleAttach,
          ),
        ],
      ),
    );
  }

  Future<void> _handleAttach() async {
    final path = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: StellarColors.bgElevated,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => const AttachmentPickerSheet(),
    );
    if (path == null || path == 'voice' || !mounted) return;

    final file = File(path);
    if (!await file.exists()) return;
    final bytes = await file.readAsBytes();
    final mimeType = _guessMimeType(path);

    final chatsAsync = ref.read(chatListProvider);
    final chat = chatsAsync.maybeWhen(
      data: (chats) => chats.where((c) => c.chatId == widget.chatId).cast<Chat?>().firstOrNull,
      orElse: () => null,
    );
    final ttl = _perMessageTtlOverride >= 0 ? _perMessageTtlOverride : (chat?.defaultTtlSeconds ?? TtlPreset.oneHour);
    final recipientNickname = widget.chatId.startsWith('direct_')
        ? widget.chatId.substring('direct_'.length)
        : widget.chatId;

    await ref.read(chatRepositoryProvider).sendDirectMessage(
          chatId: widget.chatId,
          recipientNickname: recipientNickname,
          plaintext: '📎 Attachment',
          ttlSeconds: ttl,
          attachmentBytes: bytes,
          attachmentMimeType: mimeType,
        );

    ref.invalidate(chatMessagesProvider(widget.chatId));
    ref.invalidate(chatListProvider);
  }

  String _guessMimeType(String path) {
    final ext = path.split('.').last.toLowerCase();
    switch (ext) {
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'png':
        return 'image/png';
      case 'mp4':
        return 'video/mp4';
      case 'mov':
        return 'video/quicktime';
      case 'pdf':
        return 'application/pdf';
      default:
        return 'application/octet-stream';
    }
  }

  Future<void> _handleSend() async {
    final text = _composerController.text.trim();
    if (text.isEmpty) return;

    final chatsAsync = ref.read(chatListProvider);
    final chat = chatsAsync.maybeWhen(
      data: (chats) => chats.where((c) => c.chatId == widget.chatId).cast<Chat?>().firstOrNull,
      orElse: () => null,
    );
    final ttl = _perMessageTtlOverride >= 0 ? _perMessageTtlOverride : (chat?.defaultTtlSeconds ?? TtlPreset.oneHour);

    // chatId convention from ChatListScreen._promptNewDirectChat is
    // "direct_<nickname>" — recipient resolution kept simple here; a
    // production build would store the recipient nickname as a first-class
    // column rather than deriving it from the chat id.
    final recipientNickname = widget.chatId.startsWith('direct_')
        ? widget.chatId.substring('direct_'.length)
        : widget.chatId;

    _composerController.clear();
    final replyId = _replyingTo?.messageId;
    setState(() => _replyingTo = null);

    await ref.read(chatRepositoryProvider).sendDirectMessage(
          chatId: widget.chatId,
          recipientNickname: recipientNickname,
          plaintext: text,
          ttlSeconds: ttl,
          replyToId: replyId,
        );

    ref.invalidate(chatMessagesProvider(widget.chatId));
    ref.invalidate(chatListProvider);
  }

  Future<void> _showChatTtlPicker(Chat? chat) async {
    if (chat == null) return;
    final selected = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: StellarColors.bgElevated,
      builder: (_) => TtlPickerSheet(current: chat.defaultTtlSeconds, title: 'Default disappearing timer'),
    );
    if (selected != null) {
      await ref.read(chatRepositoryProvider).updateChatTtl(widget.chatId, selected);
      ref.invalidate(chatListProvider);
    }
  }

  Future<void> _showComposerTtlPicker(Chat? chat) async {
    final selected = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: StellarColors.bgElevated,
      builder: (_) => TtlPickerSheet(
        current: _perMessageTtlOverride >= 0 ? _perMessageTtlOverride : (chat?.defaultTtlSeconds ?? TtlPreset.oneHour),
        title: 'This message disappears after',
      ),
    );
    if (selected != null) setState(() => _perMessageTtlOverride = selected);
  }
}

class _DisappearingBanner extends StatelessWidget {
  const _DisappearingBanner({required this.ttlSeconds, required this.onTap});
  final int ttlSeconds;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        color: StellarColors.bgElevated,
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.timer_outlined, size: 14, color: StellarColors.textSecondary),
            const SizedBox(width: 6),
            Text(
              'Messages disappear after ${TtlPreset.label(ttlSeconds)} · tap to change',
              style: const TextStyle(fontSize: 12, color: StellarColors.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}

class _ReplyPreview extends StatelessWidget {
  const _ReplyPreview({required this.message, required this.onCancel});
  final Message message;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      color: StellarColors.bgSurface,
      child: Row(
        children: [
          Container(width: 3, height: 32, color: StellarColors.accentBlue),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(message.senderId,
                    style: const TextStyle(color: StellarColors.accentBlue, fontSize: 12, fontWeight: FontWeight.w600)),
                Text(message.bodyPlaintext, maxLines: 1, overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
          IconButton(icon: const Icon(Icons.close, size: 18), onPressed: onCancel),
        ],
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({required this.controller, required this.onSend, required this.onPickTtl, required this.onAttach});
  final TextEditingController controller;
  final VoidCallback onSend;
  final VoidCallback onPickTtl;
  final VoidCallback onAttach;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.add_circle_outline, color: StellarColors.textSecondary),
              onPressed: onAttach,
            ),
            IconButton(
              icon: const Icon(Icons.timer_outlined, color: StellarColors.textSecondary),
              onPressed: onPickTtl,
            ),
            Expanded(
              child: TextField(
                controller: controller,
                minLines: 1,
                maxLines: 5,
                decoration: const InputDecoration(hintText: 'Message'),
              ),
            ),
            const SizedBox(width: 4),
            Container(
              decoration: const BoxDecoration(shape: BoxShape.circle, gradient: StellarColors.stellarGradient),
              child: IconButton(
                icon: const Icon(Icons.arrow_upward, color: Colors.white),
                onPressed: onSend,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
