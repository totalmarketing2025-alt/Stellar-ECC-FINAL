import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'dart:typed_data';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/stellar_theme.dart';
import '../../../l10n/stellar_translations.dart';
import '../../../domain/models/message.dart';
import '../../../domain/models/call_event.dart';
import '../../../domain/models/chat.dart';
import '../../state/app_providers.dart';
import '../../widgets/stellar_avatar.dart';
import '../../widgets/message_bubble.dart';
import '../../widgets/typing_indicator.dart';
import '../../widgets/call_event_card.dart';
import '../../widgets/ttl_picker_sheet.dart';
import '../../widgets/attachment_picker_sheet.dart';
import '../../widgets/attachment_view_policy_sheet.dart';
import '../../../core/media/attachment_payload.dart';

class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key, required this.chatId, this.desktopMode = false});
  final String chatId;
  final bool desktopMode;

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final _composerController = TextEditingController();
  final _scrollController = ScrollController();
  final _searchController = TextEditingController();
  bool _searchMode = false;
  Timer? _typingStopTimer;
  Timer? _typingHeartbeatTimer;
  bool _typingActive = false;
  Timer? _refreshTimer;
  Message? _replyingTo;
  int _perMessageTtlOverride = -1; // -1 = use chat default

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _markChatRead();
    });

    _refreshTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      ref.invalidate(chatMessagesProvider(widget.chatId));
      ref.invalidate(chatListProvider);
    });
  }

  Future<void> _markChatRead() async {
    try {
      await ref.read(chatRepositoryProvider).markChatRead(widget.chatId);
      ref.invalidate(chatListProvider);
    } catch (_) {
      // Read-state failure must not break the chat UI.
    }
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _typingStopTimer?.cancel();
    _typingHeartbeatTimer?.cancel();
    if (_typingActive) _sendTypingSignal(false);
    _searchController.dispose();
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
        automaticallyImplyLeading: !widget.desktopMode,
        leading: widget.desktopMode
            ? null
            : IconButton(
                icon: const Icon(Icons.arrow_back),
                tooltip: stellarText(context, "Back"),
                onPressed: () {
                  if (context.canPop()) {
                    context.pop();
                  } else {
                    context.go('/chats');
                  }
                },
              ),
        titleSpacing: 0,
        title: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: chat?.chatType == ChatType.direct && chat?.peerName != null
              ? () => context.push('/profile/${Uri.encodeComponent(chat!.peerName!)}')
              : null,
          child: Row(
            children: [
              StellarAvatar(
                seed: widget.chatId,
                label: chat?.displayName ?? '?',
                size: 36,
                photoBytes: chat?.chatType == ChatType.direct &&
                        chat?.peerName != null
                    ? ref
                        .watch(profilePhotoBytesProvider(chat!.peerName!))
                        .asData
                        ?.value
                    : null,
              ),
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
        ),
        actions: [
          IconButton(
            tooltip: stellarText(context, "Search messages"),
            icon: Icon(_searchMode ? Icons.close : Icons.search),
            onPressed: () => setState(() {
              _searchMode = !_searchMode;
              _searchController.clear();
            }),
          ),
          const _StellarConnectionIndicator(),
          IconButton(
            icon: const Icon(Icons.call_outlined),
            tooltip: stellarText(context, "Voice call"),
            onPressed: chat?.chatType == ChatType.direct
                ? () => context.push('/call/voice/${widget.chatId}')
                : chat?.chatType == ChatType.group
                    ? () => context.push('/group/call/${Uri.encodeComponent(widget.chatId)}')
                    : null,
          ),
          IconButton(
            icon: const Icon(Icons.videocam_outlined),
            tooltip: stellarText(context, "Video call"),
            onPressed: chat?.chatType == ChatType.direct
                ? () => context.push('/call/video/${widget.chatId}')
                : chat?.chatType == ChatType.group
                    ? () => context.push('/group/call/${Uri.encodeComponent(widget.chatId)}?video=1')
                    : null,
          ),
        ],
      ),
      body: Column(
        children: [
          _DisappearingBanner(
            ttlSeconds: chat?.defaultTtlSeconds ?? TtlPreset.oneHour,
            onTap: () => _showChatTtlPicker(chat),
          ),
          if (_searchMode)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 4),
              child: TextField(
                controller: _searchController,
                autofocus: true,
                decoration: InputDecoration(
                  hintText: stellarText(context, "Search messages"),
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => setState(() => _searchController.clear()),
                  ),
                ),
                onChanged: (_) => setState(() {}),
              ),
            ),
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(
                  child: Image.asset(
                    'assets/images/chat_background.png',
                    fit: BoxFit.cover,
                  ),
                ),
                Positioned.fill(
                  child: ColoredBox(
                    color: Colors.black.withOpacity(0.42),
                  ),
                ),
                Positioned.fill(
                  child: messagesAsync.when(
                    loading: () =>
                        const Center(child: CircularProgressIndicator()),
                    error: (err, st) => Center(
                      child: Text(
                        'Failed to load messages: $err',
                        style: const TextStyle(color: StellarColors.danger),
                      ),
                    ),
                    data: (messages) {
                      final query = _searchController.text.trim().toLowerCase();
                      final visibleMessages = query.isEmpty
                          ? messages
                          : messages.where((m) => !m.isDeleted && m.bodyPlaintext.toLowerCase().contains(query)).toList();
                      if (visibleMessages.isEmpty) {
                        return Center(
                          child: Text(
                            _searchMode && query.isNotEmpty
                                ? stellarText(context, "No matching messages")
                                : 'No messages yet — say hello 👋',
                            style: const TextStyle(
                              color: StellarColors.textSecondary,
                            ),
                          ),
                        );
                      }
                      final messagesById = {
                        for (final entry in messages)
                          entry.messageId: entry,
                      };
                      final timeline = _buildChatTimeline(visibleMessages);
                      return ListView.builder(
                        controller: _scrollController,
                        reverse: true,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        itemCount: timeline.length,
                        itemBuilder: (context, index) {
                          final item = timeline[timeline.length - 1 - index];
                          final localNickname =
                              ref.read(localNicknameProvider);

                          if (item.callGroup != null) {
                            return CallEventCard(
                              events: item.callGroup!.messages,
                              localNickname: localNickname ?? '',
                            );
                          }

                          final message = item.message!;
                          return MessageBubble(
                            message: message,
                            replyMessage: message.replyToId == null
                                ? null
                                : messagesById[message.replyToId],
                            onForward: () => _forwardMessage(message),
                            isOutgoing: message.senderId == localNickname,
                            onReply: () =>
                                setState(() => _replyingTo = message),
                            onReact: (emoji) {
                              ref
                                  .read(chatRepositoryProvider)
                                  .addReaction(message.messageId, emoji)
                                  .then((_) {
                                if (!mounted) return;
                                ref.invalidate(
                                  chatMessagesProvider(widget.chatId),
                                );
                                ref.invalidate(chatListProvider);
                              }).catchError((Object error) {
                                if (!mounted) return;
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text('Reaction failed: $error'),
                                  ),
                                );
                              });
                            },
                            onEdit: () => _editMessage(message),
                            onDeleteForEveryone: () => _deleteForEveryone(message),
                            onTogglePin: () async {
                              try {
                                await ref.read(chatRepositoryProvider).setMessagePinned(
                                      message.messageId,
                                      !message.isPinned,
                                    );
                                ref.invalidate(chatMessagesProvider(widget.chatId));
                              } catch (error) {
                                if (mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(content: Text('$error')),
                                  );
                                }
                              }
                            },
                            onDelete: () async {
                              await ref
                                  .read(chatRepositoryProvider)
                                  .deleteMessage(message.messageId);
                              ref.invalidate(
                                chatMessagesProvider(widget.chatId),
                              );
                              ref.invalidate(chatListProvider);
                            },
                            onLoadAttachment: (blobId) => ref
                                .read(chatRepositoryProvider)
                                .loadAttachment(blobId),
                            onBeginEphemeralView: (messageId) => ref
                                .read(chatRepositoryProvider)
                                .beginAttachmentView(messageId),
                            onFinishEphemeralView: (messageId) => ref
                                .read(chatRepositoryProvider)
                                .finishAttachmentView(messageId),
                          );
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          ..._typingIndicatorWidgets(),
          if ((chat?.unreadCount ?? 0) > 0)
            _NewMessagesBanner(
              count: chat!.unreadCount,
              onTap: () async {
                await _markChatRead();
                if (mounted && _scrollController.hasClients) {
                  await _scrollController.animateTo(
                    0,
                    duration: const Duration(milliseconds: 250),
                    curve: Curves.easeOut,
                  );
                }
              },
            ),
          if (_replyingTo != null) _ReplyPreview(
            message: _replyingTo!,
            onCancel: () => setState(() => _replyingTo = null),
          ),
          _Composer(
            controller: _composerController,
            onSend: _handleSend,
            onVoice: _recordVoiceMessage,
            onAttach: _handleAttach,
            onChanged: _handleComposerChanged,
          ),
        ],
      ),
    );
  }

  List<_ChatTimelineItem> _buildChatTimeline(List<Message> messages) {
    final timeline = <_ChatTimelineItem>[];
    final groups = <String, _CallEventTimelineGroup>{};

    for (final message in messages) {
      final event = CallEventPayload.tryParse(message.bodyPlaintext);
      if (event == null || event.chatId != widget.chatId) {
        timeline.add(_ChatTimelineItem.message(message));
        continue;
      }

      final group = groups.putIfAbsent(event.callId, () {
        final created = _CallEventTimelineGroup();
        timeline.add(_ChatTimelineItem.call(created));
        return created;
      });
      group.messages.add(message);
    }

    return timeline;
  }

  Future<void> _forwardMessage(Message message) async {
    if (message.isEphemeralAttachment) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            stellarText(context, 'View-once media cannot be forwarded.'),
          ),
        ),
      );
      return;
    }
    final chatsAsync = ref.read(chatListProvider);
    final chats = chatsAsync.maybeWhen(
      data: (items) => items
          .where((chat) => chat.chatId != widget.chatId)
          .toList(),
      orElse: () => <Chat>[],
    );

    if (chats.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(stellarText(context, "No other chats available to forward to."))),
      );
      return;
    }

    final target = await showModalBottomSheet<Chat>(
      context: context,
      backgroundColor: StellarColors.bgElevated,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              title: Text(stellarText(sheetContext, "Forward to chat"), style: TextStyle(fontWeight: FontWeight.w600)),
            ),
            for (final chat in chats)
              ListTile(
                leading: StellarAvatar(
                  seed: chat.chatId,
                  label: chat.displayName,
                  size: 38,
                ),
                title: Text(chat.displayName),
                subtitle: Text(chat.chatType == ChatType.group ? stellarText(context, "Group") : stellarText(context, "Direct chat")),
                onTap: () => Navigator.pop(sheetContext, chat),
              ),
          ],
        ),
      ),
    );

    if (!mounted || target == null) return;

    try {
      Uint8List? attachmentBytes;
      if (message.mediaBlobId != null) {
        attachmentBytes = await ref
            .read(chatRepositoryProvider)
            .loadAttachment(message.mediaBlobId!);
      }

      await ref.read(chatRepositoryProvider).sendDirectMessage(
        chatId: target.chatId,
        plaintext: message.bodyPlaintext,
        ttlSeconds: target.defaultTtlSeconds,
        attachmentBytes: attachmentBytes,
        attachmentMimeType: attachmentBytes == null
            ? null
            : message.mediaMimeType,
      );

      if (!mounted) return;
      ref.invalidate(chatMessagesProvider(target.chatId));
      ref.invalidate(chatListProvider);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Message forwarded to ${target.displayName}')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Forward failed: $error')),
      );
    }
  }

  Future<void> _handleAttach() async {
    final path = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: StellarColors.bgElevated,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => const AttachmentPickerSheet(),
    );
    if (!mounted || path == null) return;

    if (path == 'ttl') {
      final chatsAsync = ref.read(chatListProvider);
      final selectedChat = chatsAsync.maybeWhen(
        data: (chats) => chats.where((c) => c.chatId == widget.chatId).cast<Chat?>().firstOrNull,
        orElse: () => null,
      );
      await _showComposerTtlPicker(selectedChat);
      return;
    }

    final file = File(path);
    if (!await file.exists()) return;

    final fileLength = await file.length();

    if (fileLength > AttachmentPayload.maxBytes) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Attachment is too large. Maximum size is 8 MB.'),
            duration: Duration(seconds: 4),
          ),
        );
      }
      return;
    }

    final bytes = await file.readAsBytes();
    final mimeType = _guessMimeType(path);
    var viewPolicy = const AttachmentViewPolicy.normal();
    if (mimeType.startsWith('image/') || mimeType.startsWith('video/')) {
      final selectedPolicy = await showModalBottomSheet<AttachmentViewPolicy>(
        context: context,
        backgroundColor: StellarColors.bgElevated,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        builder: (_) => const AttachmentViewPolicySheet(),
      );
      if (!mounted || selectedPolicy == null) return;
      viewPolicy = selectedPolicy;
    }

    final chatsAsync = ref.read(chatListProvider);
    final chat = chatsAsync.maybeWhen(
      data: (chats) => chats.where((c) => c.chatId == widget.chatId).cast<Chat?>().firstOrNull,
      orElse: () => null,
    );
    final ttl = _perMessageTtlOverride >= 0 ? _perMessageTtlOverride : (chat?.defaultTtlSeconds ?? TtlPreset.oneHour);

    try {
      await ref.read(chatRepositoryProvider).sendDirectMessage(
            chatId: widget.chatId,
            plaintext: '📎 Attachment',
            ttlSeconds: ttl,
            attachmentBytes: bytes,
            attachmentMimeType: mimeType,
            attachmentViewMode: viewPolicy.mode,
            attachmentViewSeconds: viewPolicy.seconds,
            replyToId: _replyingTo?.messageId,
          );

      if (mounted && _replyingTo != null) {
        setState(() => _replyingTo = null);
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Attachment could not be sent: $error'),
            duration: const Duration(seconds: 6),
          ),
        );
      }
    } finally {
      ref.invalidate(chatMessagesProvider(widget.chatId));
      ref.invalidate(chatListProvider);
    }
  }


  Future<void> _recordVoiceMessage() async {
    final recorder = AudioRecorder();
    String? recordingPath;
    bool recordingStarted = false;

    try {
      final hasPermission = await recorder.hasPermission();
      if (!hasPermission) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(stellarText(context, "Microphone permission is required."))),
          );
        }
        return;
      }

      final directory = await getTemporaryDirectory();
      recordingPath =
          '${directory.path}/stellar_voice_${DateTime.now().microsecondsSinceEpoch}.m4a';

      await recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          bitRate: 96000,
          sampleRate: 44100,
        ),
        path: recordingPath,
      );
      recordingStarted = true;

      if (!mounted) return;

      final shouldSend = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => AlertDialog(
          title: Text(stellarText(context, "Voice message")),
          content: const Text(
            'Recording is in progress. Press Stop & Send when finished, '
            'or Cancel to discard the recording.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(stellarText(context, "Cancel")),
            ),
            FilledButton.icon(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              icon: const Icon(Icons.stop),
              label: Text(stellarText(context, "Stop & Send")),
            ),
          ],
        ),
      );

      final stoppedPath = await recorder.stop();
      recordingStarted = false;

      if (shouldSend != true || stoppedPath == null || !mounted) return;

      final file = File(stoppedPath);
      if (!await file.exists()) {
        throw StateError('The recording file was not created.');
      }

      final length = await file.length();
      if (length == 0) {
        throw StateError('The recording is empty.');
      }

      if (length > AttachmentPayload.maxBytes) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Voice message exceeds the 8 MB limit.'),
            ),
          );
        }
        return;
      }

      final bytes = await file.readAsBytes();
      if (!mounted) return;

      await _sendVoiceMessage(bytes);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not record voice message: $error')),
        );
      }
    } finally {
      if (recordingStarted) {
        try {
          await recorder.stop();
        } catch (_) {}
      }

      try {
        await recorder.dispose();
      } catch (_) {}

      if (recordingPath != null) {
        try {
          final file = File(recordingPath);
          if (await file.exists()) await file.delete();
        } catch (_) {}
      }
    }
  }

  Future<void> _sendVoiceMessage(Uint8List bytes) async {
    final chatsAsync = ref.read(chatListProvider);
    final chat = chatsAsync.maybeWhen(
      data: (chats) => chats
          .where((c) => c.chatId == widget.chatId)
          .cast<Chat?>()
          .firstOrNull,
      orElse: () => null,
    );

    final ttl = _perMessageTtlOverride >= 0
        ? _perMessageTtlOverride
        : (chat?.defaultTtlSeconds ?? TtlPreset.oneHour);

    await ref.read(chatRepositoryProvider).sendDirectMessage(
      chatId: widget.chatId,
      plaintext: '🎤 Voice message',
      ttlSeconds: ttl,
      attachmentBytes: bytes,
      attachmentMimeType: 'audio/mp4',
      replyToId: _replyingTo?.messageId,
    );

    if (!mounted) return;
    if (_replyingTo != null) {
      setState(() => _replyingTo = null);
    }
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

  void _sendTypingSignal(bool isTyping) {
    unawaited(
      ref
          .read(chatRepositoryProvider)
          .sendTypingState(widget.chatId, isTyping)
          .catchError((Object _) {}),
    );
  }

  void _handleComposerChanged(String value) {
    _typingStopTimer?.cancel();
    if (value.trim().isEmpty) {
      if (_typingActive) _sendTypingSignal(false);
      _typingActive = false;
      _typingHeartbeatTimer?.cancel();
      return;
    }
    if (!_typingActive) {
      _typingActive = true;
      _sendTypingSignal(true);
      _typingHeartbeatTimer = Timer.periodic(const Duration(seconds: 3), (_) {
        if (_typingActive) _sendTypingSignal(true);
      });
    }
    _typingStopTimer = Timer(const Duration(milliseconds: 1600), () {
      if (!_typingActive) return;
      _typingActive = false;
      _typingHeartbeatTimer?.cancel();
      _sendTypingSignal(false);
    });
  }

  List<Widget> _typingIndicatorWidgets() {
    final names = ref.watch(chatTypingIndicatorProvider)[widget.chatId] ?? <String>{};
    if (names.isEmpty) return const [];
    final label = names.length == 1
        ? '${names.first} ${stellarText(context, "is typing")}'
        : '${names.take(2).join(', ')} ${stellarText(context, "are typing")}';
    return [TypingIndicator(label: label)];
  }

  Future<void> _editMessage(Message message) async {
    final controller = TextEditingController(text: message.bodyPlaintext);
    final value = await showDialog<String>(context: context, builder: (dialogContext) => AlertDialog(
      title: Text(stellarText(context, "Edit message")),
      content: TextField(controller: controller, autofocus: true, maxLines: 5, maxLength: 4000),
      actions: [TextButton(onPressed: () => Navigator.pop(dialogContext), child: Text(stellarText(context, "Cancel"))),
        FilledButton(onPressed: () => Navigator.pop(dialogContext, controller.text), child: Text(stellarText(context, "Save")))],
    ));
    controller.dispose();
    if (value == null || value.trim().isEmpty) return;
    try {
      await ref.read(chatRepositoryProvider).editMessage(message.messageId, value);
      ref.invalidate(chatMessagesProvider(widget.chatId));
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$error')));
    }
  }

  Future<void> _deleteForEveryone(Message message) async {
    final confirmed = await showDialog<bool>(context: context, builder: (dialogContext) => AlertDialog(
      title: Text(stellarText(context, "Delete for everyone?")),
      content: Text(stellarText(context, "This message will be removed for everyone when their devices receive the update.")),
      actions: [TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: Text(stellarText(context, "Cancel"))),
        FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: Text(stellarText(context, "Delete for everyone")))],
    ));
    if (confirmed != true) return;
    try {
      await ref.read(chatRepositoryProvider).deleteMessageForEveryone(message.messageId);
      ref.invalidate(chatMessagesProvider(widget.chatId));
      ref.invalidate(chatListProvider);
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$error')));
    }
  }

  Future<void> _handleSend() async {
    if (_typingActive) { _typingActive = false; _typingStopTimer?.cancel(); _typingHeartbeatTimer?.cancel(); _sendTypingSignal(false); }
    final text = _composerController.text.trim();
    if (text.isEmpty) return;

    final chatsAsync = ref.read(chatListProvider);
    final chat = chatsAsync.maybeWhen(
      data: (chats) => chats.where((c) => c.chatId == widget.chatId).cast<Chat?>().firstOrNull,
      orElse: () => null,
    );
    final ttl = _perMessageTtlOverride >= 0 ? _perMessageTtlOverride : (chat?.defaultTtlSeconds ?? TtlPreset.oneHour);

    // chatId convention from ChatListScreen._promptNewDirectChat is

    _composerController.clear();
    final replyId = _replyingTo?.messageId;
    setState(() => _replyingTo = null);

    try {
      await ref.read(chatRepositoryProvider).sendDirectMessage(
            chatId: widget.chatId,
            plaintext: text,
            ttlSeconds: ttl,
            replyToId: replyId,
          );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('SEND ERROR: $e'),
            duration: const Duration(seconds: 8),
          ),
        );
      }
      return;
    }

    ref.invalidate(chatMessagesProvider(widget.chatId));
    ref.invalidate(chatListProvider);
  }

  Future<void> _showChatTtlPicker(Chat? chat) async {
    if (chat == null) return;
    final selected = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: StellarColors.bgElevated,
      builder: (_) => TtlPickerSheet(current: chat.defaultTtlSeconds, title: stellarText(context, "Default disappearing timer")),
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
        title: stellarText(context, "This message disappears after"),
      ),
    );
    if (selected != null) setState(() => _perMessageTtlOverride = selected);
  }
}


class _StellarConnectionIndicator extends ConsumerStatefulWidget {
  const _StellarConnectionIndicator();

  @override
  ConsumerState<_StellarConnectionIndicator> createState() =>
      _StellarConnectionIndicatorState();
}

class _StellarConnectionIndicatorState
    extends ConsumerState<_StellarConnectionIndicator> {
  Timer? _timer;
  bool _online = false;
  bool _pulse = true;

  @override
  void initState() {
    super.initState();

    _updateStatus();

    _timer = Timer.periodic(
      const Duration(milliseconds: 650),
      (_) => _updateStatus(),
    );
  }

  void _updateStatus() {
    if (!mounted) return;

    final online = ref.read(relayClientProvider).isConnected;

    setState(() {
      if (online != _online) {
        _pulse = true;
      } else if (online) {
        _pulse = !_pulse;
      }

      _online = online;
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = _online
        ? StellarColors.success.withOpacity(_pulse ? 0.98 : 0.48)
        : StellarColors.textSecondary.withOpacity(0.30);

    return Padding(
      padding: const EdgeInsets.only(left: 4, right: 2),
      child: Center(
        child: AnimatedOpacity(
          opacity: _online ? (_pulse ? 1.0 : 0.58) : 0.52,
          duration: const Duration(milliseconds: 280),
          child: Text(
            'S+V🔒',
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.2,
            ),
          ),
        ),
      ),
    );
  }
}

class _NewMessagesBanner extends StatelessWidget {
  const _NewMessagesBanner({
    required this.count,
    required this.onTap,
  });

  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Material(
        color: StellarColors.bgElevated,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(18),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.mark_chat_unread_outlined,
                  size: 18,
                ),
                const SizedBox(width: 8),
                Text(
                  count == 1 ? 'New message' : '$count new messages',
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 6),
                const Icon(
                  Icons.keyboard_arrow_down,
                  size: 18,
                ),
              ],
            ),
          ),
        ),
      ),
    );
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
  const _Composer({required this.controller, required this.onSend, required this.onVoice, required this.onAttach, required this.onChanged});
  final TextEditingController controller;
  final VoidCallback onSend;
  final VoidCallback onVoice;
  final VoidCallback onAttach;
  final ValueChanged<String> onChanged;

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
              tooltip: stellarText(context, "Voice message"),
              icon: const Icon(Icons.mic_none_outlined, color: StellarColors.textSecondary),
              onPressed: onVoice,
            ),
            Expanded(
              child: TextField(
                controller: controller,
                minLines: 1,
                maxLines: 5,
                onChanged: onChanged,
                decoration: InputDecoration(hintText: stellarText(context, "Message")),
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


class _ChatTimelineItem {
  const _ChatTimelineItem.message(this.message) : callGroup = null;
  const _ChatTimelineItem.call(this.callGroup) : message = null;

  final Message? message;
  final _CallEventTimelineGroup? callGroup;
}

class _CallEventTimelineGroup {
  final List<Message> messages = <Message>[];
}
