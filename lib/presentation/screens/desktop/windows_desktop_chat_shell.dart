import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/stellar_theme.dart';
import '../../../l10n/stellar_translations.dart';
import '../../state/app_providers.dart';
import '../chat/chat_screen.dart';
import '../chat_list/chat_list_screen.dart';

/// Three-pane desktop workspace used by the Windows build.
class WindowsDesktopChatShell extends ConsumerWidget {
  const WindowsDesktopChatShell({super.key, this.chatId, this.mainContent});

  final String? chatId;
  final Widget? mainContent;

  Future<void> _startChat(BuildContext context, WidgetRef ref) async {
    final controller = TextEditingController();
    final nickname = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(stellarText(context, 'Start a chat')),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(
            hintText: stellarText(context, '@nickname'),
          ),
          onSubmitted: (value) => Navigator.pop(dialogContext, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(stellarText(context, 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: Text(stellarText(context, 'Start')),
          ),
        ],
      ),
    );
    controller.dispose();

    final peerName = nickname
        ?.trim()
        .replaceFirst(RegExp(r'^@'), '')
        .toLowerCase();
    if (peerName == null || peerName.isEmpty || !context.mounted) return;

    final newChatId = 'direct_$peerName';
    await ref.read(chatRepositoryProvider).createDirectChat(
          chatId: newChatId,
          displayName: peerName,
          peerName: peerName,
          peerDeviceId: 1,
        );
    ref.invalidate(chatListProvider);
    if (context.mounted) context.go('/chat/$newChatId');
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!Platform.isWindows) {
      return chatId == null
          ? const ChatListScreen()
          : ChatScreen(chatId: chatId!);
    }

    final path = GoRouterState.of(context).uri.path;
    final selectedDestination = path.startsWith('/settings')
        ? 2
        : path.startsWith('/security')
            ? 1
            : 0;

    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        SingleActivator(LogicalKeyboardKey.keyN, control: true):
            () => _startChat(context, ref),
        SingleActivator(LogicalKeyboardKey.digit1, control: true):
            () => context.go('/chats'),
        SingleActivator(LogicalKeyboardKey.keyS, control: true, shift: true):
            () => context.go('/settings'),
        if (chatId != null && mainContent == null)
          SingleActivator(LogicalKeyboardKey.escape):
              () => context.go('/chats'),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          body: Row(
            children: [
              NavigationRail(
                minWidth: 76,
                groupAlignment: -0.85,
                labelType: NavigationRailLabelType.all,
                selectedIndex: selectedDestination,
                leading: const Padding(
                  padding: EdgeInsets.only(bottom: 24),
                  child: Icon(
                    Icons.shield_moon_outlined,
                    color: StellarColors.accentBlue,
                    size: 28,
                  ),
                ),
                destinations: [
                  NavigationRailDestination(
                    icon: const Icon(Icons.chat_bubble_outline),
                    selectedIcon: const Icon(Icons.chat_bubble),
                    label: Text(stellarText(context, 'Chats')),
                  ),
                  NavigationRailDestination(
                    icon: const Icon(Icons.shield_outlined),
                    selectedIcon: const Icon(Icons.shield),
                    label: Text(stellarText(context, 'Security')),
                  ),
                  NavigationRailDestination(
                    icon: const Icon(Icons.settings_outlined),
                    selectedIcon: const Icon(Icons.settings),
                    label: Text(stellarText(context, 'Settings')),
                  ),
                ],
                onDestinationSelected: (index) {
                  switch (index) {
                    case 0:
                      context.go('/chats');
                      break;
                    case 1:
                      context.go('/security');
                      break;
                    case 2:
                      context.go('/settings');
                      break;
                  }
                },
              ),
              const VerticalDivider(width: 1, thickness: 1),
              SizedBox(
                width: 360,
                child: ChatListScreen(selectedChatId: chatId),
              ),
              const VerticalDivider(width: 1, thickness: 1),
              Expanded(
                child: mainContent ??
                    (chatId == null
                        ? const _DesktopWelcomePanel()
                        : ChatScreen(
                            key: ValueKey(chatId),
                            chatId: chatId!,
                            desktopMode: true,
                          )),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DesktopWelcomePanel extends StatelessWidget {
  const _DesktopWelcomePanel();

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: StellarColors.bgBase,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.forum_outlined,
              size: 58,
              color: StellarColors.accentBlue,
            ),
            const SizedBox(height: 16),
            Text(
              stellarText(context, 'Select a conversation'),
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              stellarText(context, 'Your private chats will appear here.'),
              style: const TextStyle(color: StellarColors.textSecondary),
            ),
            const SizedBox(height: 20),
            const Text(
              'Ctrl+N  ·  New chat',
              style: TextStyle(color: StellarColors.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}
