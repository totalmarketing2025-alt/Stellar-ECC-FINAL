import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/stellar_theme.dart';
import '../../state/app_providers.dart';
import '../../widgets/stellar_avatar.dart';
import '../../widgets/ttl_picker_sheet.dart';
import '../../../domain/models/chat.dart';

class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key, required this.userId});
  final String userId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final localNickname = ref.watch(localNicknameProvider);
    final isSelf = userId == localNickname;

    return Scaffold(
      appBar: AppBar(title: Text(isSelf ? 'Your Profile' : 'Profile')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Center(child: StellarAvatar(seed: userId, label: userId, size: 96)),
          const SizedBox(height: 12),
          Center(
            child: Text('@$userId', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
          ),
          const SizedBox(height: 24),
          if (isSelf) ...[
            ListTile(
              leading: const Icon(Icons.qr_code, color: StellarColors.accentBlue),
              title: const Text('Safety number / QR code'),
              onTap: () {},
            ),
            ListTile(
              leading: const Icon(Icons.warning_amber_rounded, color: StellarColors.danger),
              title: const Text('Reset Identity', style: TextStyle(color: StellarColors.danger)),
              onTap: () {},
            ),
          ] else ...[
            ListTile(
              leading: const Icon(Icons.verified_user_outlined, color: StellarColors.accentBlue),
              title: const Text('Verify safety number'),
              subtitle: const Text('Compare fingerprints to confirm no one is intercepting this chat'),
              onTap: () {},
            ),
            ListTile(
              leading: const Icon(Icons.timer_outlined, color: StellarColors.accentPurple),
              title: const Text('Chat disappearing timer'),
              onTap: () async {
                await showModalBottomSheet<int>(
                  context: context,
                  backgroundColor: StellarColors.bgElevated,
                  builder: (_) => TtlPickerSheet(current: TtlPreset.oneHour, title: 'Disappearing timer'),
                );
              },
            ),
            const Divider(color: StellarColors.bgElevated),
            ListTile(
              leading: const Icon(Icons.block, color: StellarColors.danger),
              title: const Text('Block', style: TextStyle(color: StellarColors.danger)),
              onTap: () {},
            ),
            ListTile(
              leading: const Icon(Icons.flag_outlined, color: StellarColors.danger),
              title: const Text('Report', style: TextStyle(color: StellarColors.danger)),
              onTap: () {},
            ),
          ],
        ],
      ),
    );
  }
}
