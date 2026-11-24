import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/stellar_theme.dart';
import '../../../l10n/app_localizations.dart';
import '../../../domain/models/call_session.dart';
import '../../state/app_providers.dart';

class _UpgradeChoice {
  const _UpgradeChoice(this.nickname, this.video);
  final String nickname;
  final bool video;
}

String _newGroupChatId() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  final id = bytes.map((value) => value.toRadixString(16).padLeft(2, '0')).join();
  return 'group_$id';
}

Future<void> addParticipantToActiveCall({
  required BuildContext context,
  required WidgetRef ref,
  required CallSession session,
}) async {
  final remote = session.remoteNickname?.trim();
  if (remote == null || remote.isEmpty || session.state != CallState.connected) {
    return;
  }
  final l10n = AppLocalizations.of(context);
  final controller = TextEditingController();
  var video = session.localVideoEnabled || session.remoteVideoEnabled;
  final choice = await showDialog<_UpgradeChoice>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, setDialogState) => AlertDialog(
        backgroundColor: StellarColors.bgElevated,
        title: Text(l10n.addParticipant),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: controller,
              autofocus: true,
              textInputAction: TextInputAction.done,
              decoration: InputDecoration(labelText: l10n.stellarNickname, hintText: l10n.nicknameHint),
              onSubmitted: (_) {
                final nickname = controller.text.trim().replaceFirst(RegExp(r'^@'), '');
                if (nickname.isNotEmpty) {
                  Navigator.of(dialogContext).pop(_UpgradeChoice(nickname, video));
                }
              },
            ),
            const SizedBox(height: 16),
            SegmentedButton<bool>(
              segments: [
                ButtonSegment(value: false, label: Text(l10n.voice), icon: const Icon(Icons.call)),
                ButtonSegment(value: true, label: Text(l10n.video), icon: const Icon(Icons.videocam)),
              ],
              selected: {video},
              onSelectionChanged: (values) =>
                  setDialogState(() => video = values.first),
            ),
            const SizedBox(height: 12),
            Text(l10n.groupUpgradeKeepsCallActive,
              style: TextStyle(color: StellarColors.textSecondary, fontSize: 12),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () {
              final nickname = controller.text.trim().replaceFirst(RegExp(r'^@'), '');
              if (nickname.isNotEmpty) {
                Navigator.of(dialogContext).pop(_UpgradeChoice(nickname, video));
              }
            },
            child: Text(l10n.add),
          ),
        ],
      ),
    ),
  );
  controller.dispose();
  if (choice == null || !context.mounted) return;

  final local = ref.read(localNicknameProvider)?.trim();
  final nickname = choice.nickname.trim();
  if (local == null || local.isEmpty ||
      nickname.toLowerCase() == local.toLowerCase() ||
      nickname.toLowerCase() == remote.toLowerCase()) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(l10n.chooseDifferentParticipantNickname)),
    );
    return;
  }

  final groupChatId = _newGroupChatId();
  try {
    await ref.read(chatRepositoryProvider).createGroupChat(
      chatId: groupChatId,
      displayName: '$remote + $nickname',
      memberNicknames: [remote, nickname],
    );
    if (!context.mounted) return;
    await ref.read(groupCallCoordinatorProvider).startOutgoing(
      chatId: groupChatId,
      video: choice.video,
    );
    if (!context.mounted) return;
    GoRouter.of(context).go(
      '/group/call/${Uri.encodeComponent(groupChatId)}'
      '${choice.video ? '?video=1' : ''}',
    );
  } catch (error) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Could not add participant: $error')),
    );
  }
}
