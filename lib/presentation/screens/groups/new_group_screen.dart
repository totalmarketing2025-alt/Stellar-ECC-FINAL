import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../../core/theme/stellar_theme.dart';
import '../../state/app_providers.dart';

class NewGroupScreen extends ConsumerStatefulWidget {
  const NewGroupScreen({super.key});

  @override
  ConsumerState<NewGroupScreen> createState() => _NewGroupScreenState();
}

class _NewGroupScreenState extends ConsumerState<NewGroupScreen> {
  final _nameController = TextEditingController();
  final _memberController = TextEditingController();
  final _members = <String>{};

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('New Group'),
        actions: [
          TextButton(
            onPressed: _members.isEmpty || _nameController.text.trim().isEmpty ? null : _createGroup,
            child: const Text('Create'),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(hintText: 'Group name'),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _memberController,
                    decoration: const InputDecoration(hintText: 'Add @nickname'),
                    onSubmitted: (_) => _addMember(),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.add_circle, color: StellarColors.accentBlue),
                  onPressed: _addMember,
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: _members
                  .map((m) => Chip(
                        label: Text(m),
                        backgroundColor: StellarColors.bgSurface,
                        deleteIcon: const Icon(Icons.close, size: 16),
                        onDeleted: () => setState(() => _members.remove(m)),
                      ))
                  .toList(),
            ),
          ],
        ),
      ),
    );
  }

  void _addMember() {
    final value = _memberController.text.trim();
    if (value.isEmpty) return;
    setState(() {
      _members.add(value);
      _memberController.clear();
    });
  }

  Future<void> _createGroup() async {
    final chatId = 'group_${const Uuid().v4()}';
    final repo = ref.read(chatRepositoryProvider);
    await repo.createDirectChat(chatId: chatId, displayName: _nameController.text.trim());
    // NOTE: createDirectChat is reused here for row creation only — a real
    // group flow additionally calls GroupCrypto.createOrRotateSenderKey and
    // distributes the resulting SenderKeyDistributionMessage to every
    // member's pairwise session (Phase 3 §4), wired in Module 7's
    // GroupRepository rather than duplicated inline here.
    ref.invalidate(chatListProvider);
    if (mounted) context.go('/chat/$chatId');
  }
}
