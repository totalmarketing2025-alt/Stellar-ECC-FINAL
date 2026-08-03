import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/stellar_theme.dart';
import '../../state/app_providers.dart';
import '../../state/security_providers.dart';
import '../../widgets/ttl_picker_sheet.dart';
import '../../../domain/models/chat.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  int _defaultTtl = TtlPreset.oneHour;
  String _notificationPreviewLevel = 'name-only';

  @override
  Widget build(BuildContext context) {
    final nickname = ref.watch(localNicknameProvider) ?? '—';
    final screenshotBlockEnabled = ref.watch(screenshotBlockEnabledProvider);
    final screenPrivacyMode = ref.watch(screenPrivacyModeEnabledProvider);
    final biometricLockEnabled = ref.watch(biometricLockEnabledProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.shield_outlined, color: StellarColors.accentBlue),
            title: const Text('Security Center'),
            subtitle: Text('Score: ${ref.watch(securityScoreProvider)}/100'),
            trailing: const Icon(Icons.chevron_right, color: StellarColors.textSecondary),
            onTap: () => context.push('/security'),
          ),
          const Divider(color: StellarColors.bgElevated),

          _SectionHeader('Account'),
          ListTile(
            leading: const Icon(Icons.alternate_email, color: StellarColors.accentBlue),
            title: const Text('Nickname'),
            subtitle: Text(nickname),
          ),
          ListTile(
            leading: const Icon(Icons.qr_code, color: StellarColors.accentBlue),
            title: const Text('Safety number / QR'),
            onTap: () => context.push('/security'),
          ),
          ListTile(
            leading: const Icon(Icons.warning_amber_rounded, color: StellarColors.danger),
            title: const Text('Reset Identity', style: TextStyle(color: StellarColors.danger)),
            subtitle: const Text('Invalidates all sessions — contacts must re-verify you'),
            onTap: () => _confirmResetIdentity(context),
          ),

          _SectionHeader('Privacy'),
          SwitchListTile(
            activeColor: StellarColors.accentBlue,
            title: const Text('Block screenshots'),
            subtitle: const Text('Android: fully blocked. iOS: detected + disclosed (no OS-level prevention exists)'),
            value: screenshotBlockEnabled,
            onChanged: (v) => ref.read(screenshotBlockEnabledProvider.notifier).state = v,
          ),
          SwitchListTile(
            activeColor: StellarColors.accentBlue,
            title: const Text('Screen privacy mode'),
            subtitle: const Text('Blur content when app is backgrounded'),
            value: screenPrivacyMode,
            onChanged: (v) => ref.read(screenPrivacyModeEnabledProvider.notifier).state = v,
          ),
          ListTile(
            leading: const Icon(Icons.cloud_off, color: StellarColors.textSecondary),
            title: const Text('Cloud backups'),
            subtitle: const Text('Off — app data is excluded from device backups by design'),
          ),

          _SectionHeader('Chats'),
          ListTile(
            leading: const Icon(Icons.timer_outlined, color: StellarColors.accentPurple),
            title: const Text('Default disappearing timer'),
            subtitle: Text(TtlPreset.label(_defaultTtl)),
            onTap: () async {
              final selected = await showModalBottomSheet<int>(
                context: context,
                backgroundColor: StellarColors.bgElevated,
                builder: (_) => TtlPickerSheet(current: _defaultTtl, title: 'Default disappearing timer'),
              );
              if (selected != null) setState(() => _defaultTtl = selected);
            },
          ),

          _SectionHeader('App Lock'),
          SwitchListTile(
            activeColor: StellarColors.accentBlue,
            title: const Text('Biometric / PIN lock'),
            value: biometricLockEnabled,
            onChanged: (v) => ref.read(biometricLockEnabledProvider.notifier).state = v,
          ),

          _SectionHeader('Notifications'),
          ListTile(
            leading: const Icon(Icons.notifications_outlined, color: StellarColors.accentPurple),
            title: const Text('Preview level'),
            subtitle: Text(_notificationPreviewLevelLabel(_notificationPreviewLevel)),
            onTap: () => _showPreviewLevelPicker(context),
          ),

          _SectionHeader('About'),
          ListTile(
            leading: const Icon(Icons.security, color: StellarColors.textSecondary),
            title: const Text('Security audit checklist'),
            onTap: () {},
          ),
        ],
      ),
    );
  }

  String _notificationPreviewLevelLabel(String level) {
    switch (level) {
      case 'full':
        return 'Full preview';
      case 'name-only':
        return 'Sender name only';
      default:
        return 'Silent (no preview)';
    }
  }

  void _showPreviewLevelPicker(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: StellarColors.bgElevated,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: ['full', 'name-only', 'silent']
              .map((level) => RadioListTile<String>(
                    value: level,
                    groupValue: _notificationPreviewLevel,
                    activeColor: StellarColors.accentBlue,
                    title: Text(_notificationPreviewLevelLabel(level)),
                    onChanged: (v) {
                      setState(() => _notificationPreviewLevel = v!);
                      Navigator.pop(sheetContext);
                    },
                  ))
              .toList(),
        ),
      ),
    );
  }

  void _confirmResetIdentity(BuildContext context) {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: StellarColors.bgElevated,
        title: const Text('Reset Identity?'),
        content: const Text(
          'This generates a new identity key, invalidates every existing session, '
          'and requires all your contacts to re-verify you. This cannot be undone.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Reset', style: TextStyle(color: StellarColors.danger)),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);
  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
      child: Text(
        title.toUpperCase(),
        style: const TextStyle(fontSize: 12, color: StellarColors.textSecondary, letterSpacing: 1.0),
      ),
    );
  }
}
