import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/stellar_theme.dart';
import '../../../domain/models/contact.dart';
import '../../widgets/stellar_avatar.dart';
import '../../widgets/ttl_picker_sheet.dart';
import '../../../domain/models/chat.dart';

class GroupManagementScreen extends ConsumerStatefulWidget {
  const GroupManagementScreen({super.key, required this.chatId});
  final String chatId;

  @override
  ConsumerState<GroupManagementScreen> createState() => _GroupManagementScreenState();
}

class _GroupManagementScreenState extends ConsumerState<GroupManagementScreen> {
  // Membership is loaded via a group repository (Module 7) — represented
  // here with local state for the UI, since the crypto side (Sender Key
  // rotation on membership change, Phase 3 §4) is what actually needs to
  // run when these mutate, not just the UI list.
  final List<GroupMember> _members = [];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Group Settings')),
      body: ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.timer_outlined, color: StellarColors.accentPurple),
            title: const Text('Default disappearing timer'),
            onTap: () => showModalBottomSheet<int>(
              context: context,
              backgroundColor: StellarColors.bgElevated,
              builder: (_) => TtlPickerSheet(current: TtlPreset.oneHour, title: 'Default disappearing timer'),
            ),
          ),
          const Divider(color: StellarColors.bgElevated),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Members', style: TextStyle(color: StellarColors.textSecondary, fontSize: 12)),
                TextButton.icon(
                  onPressed: _addMember,
                  icon: const Icon(Icons.person_add_alt_1, size: 16, color: StellarColors.accentBlue),
                  label: const Text('Add', style: TextStyle(color: StellarColors.accentBlue)),
                ),
              ],
            ),
          ),
          if (_members.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text('No other members yet', style: TextStyle(color: StellarColors.textSecondary)),
            ),
          ..._members.map((member) => ListTile(
                leading: StellarAvatar(seed: member.nickname, label: member.nickname, size: 40),
                title: Text(member.nickname),
                subtitle: Text(member.role.name),
                trailing: member.role != GroupRole.owner
                    ? IconButton(
                        icon: const Icon(Icons.remove_circle_outline, color: StellarColors.danger),
                        onPressed: () => _removeMember(member),
                      )
                    : null,
              )),
          const Divider(color: StellarColors.bgElevated),
          ListTile(
            leading: const Icon(Icons.exit_to_app, color: StellarColors.danger),
            title: const Text('Leave group', style: TextStyle(color: StellarColors.danger)),
            onTap: () {},
          ),
        ],
      ),
    );
  }

  void _addMember() {
    setState(() {
      // Adding here triggers a Sender Key rotation + redistribution to all
      // members in the real flow (Module 7's GroupRepository), not shown
      // as UI-only state.
    });
  }

  void _removeMember(GroupMember member) {
    setState(() => _members.remove(member));
    // Same rotation requirement applies on removal — the removed member
    // must lose access to the (still-live, unexpired) sender key chain.
  }
}
