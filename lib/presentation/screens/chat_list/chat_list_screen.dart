import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_linkify/flutter_linkify.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/stellar_theme.dart';
import '../../../core/moderation/stellar_broadcast.dart';
import '../../../domain/models/chat.dart';
import '../../state/app_providers.dart';
import '../../state/security_providers.dart';
import '../../widgets/stellar_avatar.dart';
import '../../widgets/expiry_ring.dart';

class ChatListScreen extends ConsumerStatefulWidget {
  const ChatListScreen({super.key});

  @override
  ConsumerState<ChatListScreen> createState() => _ChatListScreenState();
}

class _ChatListScreenState extends ConsumerState<ChatListScreen> {
  final _searchController = TextEditingController();
  Timer? _refreshTimer;
  Timer? _broadcastRefreshTimer;
  List<StellarBroadcast> _broadcasts = [];

  @override
  void initState() {
    super.initState();
    _refreshTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      ref.invalidate(chatListProvider);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _refreshBroadcasts();
    });
    _broadcastRefreshTimer =
        Timer.periodic(const Duration(seconds: 30), (_) {
      _expireBroadcastsLocally();
      _refreshBroadcasts();
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _broadcastRefreshTimer?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final chatsAsync = ref.watch(chatListProvider);
    final wantedModeEnabled = ref.watch(wantedModeWipeEnabledProvider);

    return Scaffold(
      appBar: AppBar(
        title: wantedModeEnabled
            ? const _WantedHeaderTitle()
            : const Text('Stellar ECC'),
        actions: [
          IconButton(
            tooltip: 'My Profile',
            icon: const Icon(Icons.account_circle_outlined),
            onPressed: () {
              final nickname = ref.read(localNicknameProvider)?.trim();
              if (nickname == null || nickname.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Your profile is not ready yet.')),
                );
                return;
              }
              context.push('/profile/${Uri.encodeComponent(nickname)}');
            },
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => context.push('/settings'),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              controller: _searchController,
              decoration: const InputDecoration(
                hintText: 'Search chats and contacts',
                prefixIcon: Icon(Icons.search, color: StellarColors.textSecondary),
              ),
              onChanged: (_) => setState(() {}),
            ),
          ),
          Expanded(
            child: chatsAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (err, st) => Center(
                child: Text('Could not load chats: $err',
                    style: const TextStyle(color: StellarColors.danger)),
              ),
              data: (chats) {
                final filtered = _filterChats(chats, _searchController.text);
                if (filtered.isEmpty && _broadcasts.isEmpty) {
                  return const _EmptyState();
                }
                return ListView.separated(
                  itemCount: _broadcasts.length + filtered.length,
                  separatorBuilder: (_, __) =>
                      const Divider(height: 1, color: StellarColors.bgElevated),
                  itemBuilder: (context, index) {
                    if (index < _broadcasts.length) {
                      return _BroadcastAnnouncementCard(
                        key: ValueKey(_broadcasts[index].broadcastId),
                        broadcast: _broadcasts[index],
                      );
                    }
                    return _ChatListTile(
                      chat: filtered[index - _broadcasts.length],
                      onLongPress: () => _showChatActions(filtered[index - _broadcasts.length]),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
      floatingActionButton: Container(
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          gradient: StellarColors.stellarGradient,
        ),
        child: FloatingActionButton(
          backgroundColor: Colors.transparent,
          elevation: 0,
          onPressed: () => _showNewChatSheet(context),
          child: const Icon(Icons.add, color: Colors.white),
        ),
      ),
    );
  }

  Future<void> _refreshBroadcasts() async {
    final nickname = ref.read(localNicknameProvider)?.trim();
    if (nickname == null || nickname.isEmpty) return;
    try {
      final items = await ref.read(moderationClientProvider).fetchBroadcasts(
            nickname: nickname,
            limit: 20,
            offset: 0,
          );
      if (!mounted) return;
      final cutoff =
          DateTime.now().millisecondsSinceEpoch - 24 * 60 * 60 * 1000;
      final active = items
          .where((item) => item.createdAt > cutoff)
          .toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

      setState(() => _broadcasts = active.isEmpty ? [] : [active.first]);
    } catch (_) {
      _expireBroadcastsLocally();
    }
  }

  void _expireBroadcastsLocally() {
    if (!mounted || _broadcasts.isEmpty) return;

    final cutoff =
        DateTime.now().millisecondsSinceEpoch - 24 * 60 * 60 * 1000;
    final active = _broadcasts
        .where((item) => item.createdAt > cutoff)
        .toList();

    if (active.length != _broadcasts.length) {
      setState(() => _broadcasts = active);
    }
  }

  List<Chat> _filterChats(List<Chat> chats, String query) {
    if (query.trim().isEmpty) return chats;
    final q = query.toLowerCase();
    return chats.where((c) => c.displayName.toLowerCase().contains(q)).toList();
  }

  Future<void> _showChatActions(Chat chat) async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: StellarColors.bgElevated,
      builder: (sheetContext) => SafeArea(child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: Icon(chat.isPinned ? Icons.push_pin_outlined : Icons.push_pin),
            title: Text(chat.isPinned ? 'Unpin Chat' : 'Pin Chat'),
            onTap: () async {
              Navigator.pop(sheetContext);
              try {
                await ref.read(chatRepositoryProvider).setChatPinned(chat.chatId, !chat.isPinned);
                ref.invalidate(chatListProvider);
              } catch (error) {
                if (mounted) ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('$error')));
              }
            },
          ),
          if (chat.chatType == ChatType.direct)
            ListTile(
              leading: const Icon(Icons.delete_outline, color: StellarColors.danger),
              title: const Text('Delete Chat'),
              onTap: () {
                Navigator.pop(sheetContext);
                _confirmDeleteChat(chat);
              },
            ),
        ],
      )),
    );
  }

  Future<void> _confirmDeleteChat(Chat chat) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete Chat?'),
        content: Text('Delete local conversation with ${chat.displayName}? '
          'This does not delete messages on the other device. '
          'New incoming messages will recreate the chat.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await ref.read(chatRepositoryProvider).deleteLocalDirectChat(chat.chatId);
      ref.invalidate(chatListProvider);
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not delete chat: $error')));
    }
  }

  void _showNewChatSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: StellarColors.bgElevated,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.person_add_alt_1, color: StellarColors.accentBlue),
              title: const Text('New direct chat'),
              onTap: () {
                Navigator.pop(sheetContext);
                _promptNewDirectChat(context);
              },
            ),
            ListTile(
              leading: const Icon(Icons.group_add, color: StellarColors.accentPurple),
              title: const Text('New group'),
              onTap: () {
                Navigator.pop(sheetContext);
                context.push('/group/new');
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _promptNewDirectChat(BuildContext context) async {
    final controller = TextEditingController();
    final nickname = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: StellarColors.bgElevated,
        title: const Text('Start a chat'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(hintText: '@nickname'),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('Start'),
          ),
        ],
      ),
    );

    if (nickname == null || nickname.isEmpty || !mounted) return;

    final peerName = nickname
        .trim()
        .replaceFirst(RegExp(r'^@'), '')
        .toLowerCase();

    if (peerName.isEmpty) return;

    final repo = ref.read(chatRepositoryProvider);
    final chatId = 'direct_$peerName';
    await repo.createDirectChat(
      chatId: chatId,
      displayName: peerName,
      peerName: peerName,
      peerDeviceId: 1,
    );
    ref.invalidate(chatListProvider);
    if (mounted) context.push('/chat/$chatId');
  }
}

class _ChatListTile extends ConsumerWidget {
  const _ChatListTile({required this.chat, required this.onLongPress});
  final Chat chat;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListTile(
      onTap: () => context.push('/chat/${chat.chatId}'),
      onLongPress: onLongPress,
      leading: StellarAvatar(
        seed: chat.chatId,
        label: chat.displayName,
        photoBytes: chat.chatType == ChatType.direct && chat.peerName != null
            ? ref
                .watch(profilePhotoBytesProvider(chat.peerName!))
                .asData
                ?.value
            : null,
      ),
      title: Row(children: [
        Flexible(child: Text(chat.displayName, overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w600))),
        if (chat.isPinned) const Padding(padding: EdgeInsets.only(left: 6),
          child: Icon(Icons.push_pin, size: 15, color: StellarColors.textSecondary)),
      ]),
      subtitle: Text(
        chat.lastMessagePreview ?? 'No messages yet',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: StellarColors.textSecondary),
      ),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (chat.oldestVisibleExpiry != null)
            ExpiryRing(expiresAt: chat.oldestVisibleExpiry!, size: 18),
          if (chat.unreadCount > 0) ...[
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: StellarColors.accentPurple,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text('${chat.unreadCount}',
                  style: const TextStyle(color: Colors.white, fontSize: 12)),
            ),
          ],
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                gradient: StellarColors.stellarGradient,
              ),
              child: const Icon(Icons.chat_bubble_outline, color: Colors.white),
            ),
            const SizedBox(height: 16),
            const Text('No chats yet', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            const Text(
              'Start a private, self-destructing conversation with the + button.',
              textAlign: TextAlign.center,
              style: TextStyle(color: StellarColors.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}



class _BroadcastAnnouncementCard extends ConsumerStatefulWidget {
  const _BroadcastAnnouncementCard({
    super.key,
    required this.broadcast,
  });

  final StellarBroadcast broadcast;

  @override
  ConsumerState<_BroadcastAnnouncementCard> createState() =>
      _BroadcastAnnouncementCardState();
}

class _BroadcastAnnouncementCardState
    extends ConsumerState<_BroadcastAnnouncementCard> {
  late final Future<Uint8List?>? _imageFuture;

  bool get _isImage =>
      widget.broadcast.attachmentMimeType?.toLowerCase().startsWith('image/') ??
      false;

  @override
  void initState() {
    super.initState();
    _imageFuture = _isImage ? _fetchAttachment() : null;
  }

  Future<Uint8List?> _fetchAttachment() async {
    final nickname = ref.read(localNicknameProvider)?.trim();
    if (nickname == null || nickname.isEmpty) return null;
    return ref.read(moderationClientProvider).fetchBroadcastAttachment(
          broadcastId: widget.broadcast.broadcastId,
          nickname: nickname,
        );
  }

  Future<void> _openAttachment() async {
    try {
      final bytes = await (_imageFuture ?? _fetchAttachment());
      if (!mounted || bytes == null) return;

      if (_isImage) {
        await showDialog<void>(
          context: context,
          barrierColor: Colors.black87,
          builder: (_) => Dialog(
            backgroundColor: Colors.black,
            insetPadding: const EdgeInsets.all(12),
            child: InteractiveViewer(
              minScale: 0.5,
              maxScale: 5,
              child: Image.memory(bytes, fit: BoxFit.contain),
            ),
          ),
        );
        return;
      }

      final mime = widget.broadcast.attachmentMimeType ?? 'Unknown file';
      final content = mime.toLowerCase().startsWith('text/plain')
          ? utf8.decode(bytes, allowMalformed: true)
          : '$mime\n${bytes.length} bytes';

      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          backgroundColor: StellarColors.bgSurface,
          title: const Text('Broadcast attachment'),
          content: SingleChildScrollView(
            child: SelectableText(content),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('CLOSE'),
            ),
          ],
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not open attachment: $error')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final broadcast = widget.broadcast;

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 10, 12, 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF142D46), Color(0xFF101D32)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: StellarColors.accentBlue.withOpacity(0.55),
        ),
        boxShadow: [
          BoxShadow(
            color: StellarColors.accentBlue.withOpacity(0.10),
            blurRadius: 14,
            spreadRadius: 1,
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.campaign_rounded,
                  color: StellarColors.accentBlue, size: 22),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'STELLAR BROADCAST',
                  style: TextStyle(
                    color: StellarColors.textPrimary,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.1,
                  ),
                ),
              ),
              _broadcastBadge('BROADCAST', StellarColors.accentBlue),
              const SizedBox(width: 6),
              _broadcastBadge('NO REPLY', StellarColors.danger),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            broadcast.title,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 7),
          Linkify(
            text: broadcast.message,
            style: const TextStyle(
              color: StellarColors.textPrimary,
              height: 1.45,
            ),
            linkStyle: const TextStyle(
              color: StellarColors.accentBlue,
              decoration: TextDecoration.underline,
            ),
            onOpen: (link) async {
              final uri = Uri.tryParse(link.url);
              if (uri != null &&
                  (uri.scheme == 'https' || uri.scheme == 'http')) {
                await launchUrl(uri,
                    mode: LaunchMode.externalApplication);
              }
            },
          ),
          if (_isImage) ...[
            const SizedBox(height: 12),
            FutureBuilder<Uint8List?>(
              future: _imageFuture,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(
                    child: Padding(
                      padding: EdgeInsets.all(12),
                      child: CircularProgressIndicator(),
                    ),
                  );
                }
                if (!snapshot.hasData || snapshot.data == null) {
                  return const Text(
                    'Image preview unavailable',
                    style: TextStyle(color: StellarColors.textSecondary),
                  );
                }
                return GestureDetector(
                  onTap: _openAttachment,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Image.memory(
                      snapshot.data!,
                      height: 190,
                      width: double.infinity,
                      fit: BoxFit.cover,
                    ),
                  ),
                );
              },
            ),
            const SizedBox(height: 5),
            const Text('Tap image to zoom',
                style: TextStyle(
                    color: StellarColors.textSecondary, fontSize: 11)),
          ] else if (broadcast.hasAttachment) ...[
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: _openAttachment,
              icon: const Icon(Icons.attach_file),
              label: const Text('OPEN ATTACHMENT'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _broadcastBadge(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.13),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withOpacity(0.65)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 9,
          fontWeight: FontWeight.bold,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

class _WantedHeaderTitle extends StatefulWidget {
  const _WantedHeaderTitle();

  @override
  State<_WantedHeaderTitle> createState() => _WantedHeaderTitleState();
}

class _WantedHeaderTitleState extends State<_WantedHeaderTitle>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
    lowerBound: 0.35,
    upperBound: 1.0,
  )..repeat(reverse: true);

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text('Stellar '),
        FadeTransition(
          opacity: _pulse,
          child: const Text(
            'WANTED',
            style: TextStyle(
              color: Color(0xFFB66DFF),
              fontWeight: FontWeight.w900,
              letterSpacing: 1.2,
            ),
          ),
        ),
      ],
    );
  }
}
