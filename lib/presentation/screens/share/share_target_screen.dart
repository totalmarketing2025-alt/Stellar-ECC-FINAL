import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/media/attachment_payload.dart';
import '../../../core/theme/stellar_theme.dart';
import '../../../domain/models/chat.dart';
import '../../../l10n/stellar_translations.dart';
import '../../state/app_providers.dart';
import '../../widgets/stellar_avatar.dart';
import '../../../core/sharing/shared_content_item.dart';

class ShareTargetScreen extends ConsumerStatefulWidget {
  const ShareTargetScreen({super.key, required this.items});

  final List<SharedContentItem> items;

  @override
  ConsumerState<ShareTargetScreen> createState() => _ShareTargetScreenState();
}

class _ShareTargetScreenState extends ConsumerState<ShareTargetScreen> {
  bool _sending = false;

  @override
  void dispose() {
    for (final item in widget.items) {
      final path = item.path;
      if (path != null) {
        final file = File(path);
        unawaited(file.delete().catchError((Object _) => file));
      }
    }
    super.dispose();
  }

  Future<void> _confirmAndSend(Chat target) async {
    if (_sending) return;
    final validItems = widget.items
        .where((item) => item.error == null &&
            (item.path != null || (item.text?.trim().isNotEmpty ?? false)))
        .toList(growable: false);
    if (validItems.isEmpty) return;

    final approved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(stellarText(dialogContext, 'Send shared content?')),
        content: Text(
          '${validItems.length} ${stellarText(dialogContext, 'shared item(s) to')} '
          '${target.displayName}?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(stellarText(dialogContext, 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(stellarText(dialogContext, 'Send')),
          ),
        ],
      ),
    );
    if (approved != true || !mounted) return;

    setState(() => _sending = true);
    var sent = 0;
    try {
      final repository = ref.read(chatRepositoryProvider);
      for (final item in validItems) {
        if (item.text?.trim().isNotEmpty == true && item.path == null) {
          await repository.sendDirectMessage(
            chatId: target.chatId,
            plaintext: item.text!.trim(),
            ttlSeconds: target.defaultTtlSeconds,
          );
          sent++;
          continue;
        }

        final path = item.path;
        if (path == null) continue;
        final file = File(path);
        if (!await file.exists()) {
          throw StateError('${item.name}: shared file is no longer available');
        }
        final length = await file.length();
        if (length > AttachmentPayload.maxBytes) {
          throw StateError(
            '${item.name}: ${stellarText(context, 'Attachment is too large. Maximum size is 8 MB.')}',
          );
        }
        final bytes = await file.readAsBytes();
        await repository.sendDirectMessage(
          chatId: target.chatId,
          plaintext: '📎 ${item.name}',
          ttlSeconds: target.defaultTtlSeconds,
          attachmentBytes: bytes,
          attachmentMimeType: item.mimeType,
        );
        sent++;
      }

      if (!mounted) return;
      ref.invalidate(chatMessagesProvider(target.chatId));
      ref.invalidate(chatListProvider);
      if (sent == validItems.length) {
        context.go('/chat/${Uri.encodeComponent(target.chatId)}');
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '${stellarText(context, 'Could not send shared content:')} $error',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final chatsAsync = ref.watch(chatListProvider);
    final invalidCount = widget.items.where((item) => item.error != null).length;

    return Scaffold(
      appBar: AppBar(title: Text(stellarText(context, 'Share to Stellar'))),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                stellarText(context, 'Choose a conversation to send the shared content.'),
                style: const TextStyle(color: StellarColors.textSecondary),
              ),
            ),
          ),
          if (invalidCount > 0)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                stellarText(context, 'Some shared items are unavailable.'),
                style: const TextStyle(color: StellarColors.danger),
              ),
            ),
          SizedBox(
            height: 150,
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              itemCount: widget.items.length,
              itemBuilder: (context, index) {
                final item = widget.items[index];
                return ListTile(
                  leading: Icon(
                    item.mimeType.startsWith('image/')
                        ? Icons.image_outlined
                        : item.mimeType.startsWith('video/')
                            ? Icons.video_file_outlined
                            : Icons.insert_drive_file_outlined,
                  ),
                  title: Text(item.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                    item.error ?? item.mimeType,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                );
              },
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: chatsAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, _) => Center(
                child: Text('${stellarText(context, 'Could not load chats:')} $error'),
              ),
              data: (chats) {
                if (chats.isEmpty) {
                  return Center(
                    child: Text(stellarText(context, 'No conversations available.')),
                  );
                }
                return ListView.builder(
                  itemCount: chats.length,
                  itemBuilder: (context, index) {
                    final chat = chats[index];
                    return ListTile(
                      leading: StellarAvatar(
                        seed: chat.chatId,
                        label: chat.displayName,
                        size: 42,
                      ),
                      title: Text(chat.displayName),
                      subtitle: Text(
                        chat.chatType == ChatType.group
                            ? stellarText(context, 'Group')
                            : stellarText(context, 'Direct chat'),
                      ),
                      trailing: _sending
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.chevron_right),
                      onTap: _sending ? null : () => _confirmAndSend(chat),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
