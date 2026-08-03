import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/stellar_theme.dart';
import '../../../domain/models/chat.dart';
import '../../state/app_providers.dart';
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

  @override
  void initState() {
    super.initState();
    // Live-refresh so expiry countdowns and previews stay current without
    // requiring a manual pull-to-refresh.
    _refreshTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      ref.invalidate(chatListProvider);
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final chatsAsync = ref.watch(chatListProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Stellar ECC'),
        actions: [
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
                if (filtered.isEmpty) {
                  return const _EmptyState();
                }
                return ListView.separated(
                  itemCount: filtered.length,
                  separatorBuilder: (_, __) =>
                      const Divider(height: 1, color: StellarColors.bgElevated),
                  itemBuilder: (context, index) => _ChatListTile(chat: filtered[index]),
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

  List<Chat> _filterChats(List<Chat> chats, String query) {
    if (query.trim().isEmpty) return chats;
    final q = query.toLowerCase();
    return chats.where((c) => c.displayName.toLowerCase().contains(q)).toList();
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

    final repo = ref.read(chatRepositoryProvider);
    final chatId = 'direct_$nickname';
    await repo.createDirectChat(chatId: chatId, displayName: nickname);
    ref.invalidate(chatListProvider);
    if (mounted) context.push('/chat/$chatId');
  }
}

class _ChatListTile extends StatelessWidget {
  const _ChatListTile({required this.chat});
  final Chat chat;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: () => context.push('/chat/${chat.chatId}'),
      leading: StellarAvatar(seed: chat.chatId, label: chat.displayName),
      title: Text(chat.displayName, style: const TextStyle(fontWeight: FontWeight.w600)),
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
