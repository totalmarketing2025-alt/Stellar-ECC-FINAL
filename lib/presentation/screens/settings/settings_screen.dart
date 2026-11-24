import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/stellar_theme.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import 'stellar_security_screen.dart';
import 'stellar_guard_screen.dart';
import '../../state/app_providers.dart';
import '../../../core/storage/providers.dart';
import '../../state/security_providers.dart';
import '../../state/app_lock_controller.dart';
import '../../widgets/ttl_picker_sheet.dart';
import '../../../domain/models/chat.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen>
    with WidgetsBindingObserver {
  int _defaultTtl = TtlPreset.oneHour;
  String _notificationPreviewLevel = 'name-only';
  static const _edgeLightingChannel =
      MethodChannel('ecc.stellar.app/edge_lighting');
  bool _edgeSupported = false;
  bool _edgePermissionGranted = false;
  bool _edgeEnabled = false;
  bool _edgeLoading = false;
  bool _edgePendingEnable = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_refreshEdgeLighting());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_refreshEdgeLighting());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _refreshEdgeLighting() async {
    if (!Platform.isAndroid) return;
    try {
      final state = await _edgeLightingChannel
          .invokeMapMethod<String, dynamic>('getState');
      if (!mounted) return;
      final supported = state?['supported'] == true;
      final granted = state?['permissionGranted'] == true;
      var enabled = state?['enabled'] == true;
      if (_edgePendingEnable && granted && supported) {
        enabled = await _edgeLightingChannel.invokeMethod<bool>(
              'setEnabled', {'enabled': true}) == true;
      }
      if (!mounted) return;
      setState(() {
        _edgeSupported = supported;
        _edgePermissionGranted = granted;
        _edgeEnabled = enabled && granted;
        _edgePendingEnable = false;
      });
    } on PlatformException {
      if (mounted) setState(() => _edgePendingEnable = false);
    } on MissingPluginException {
      if (mounted) setState(() => _edgeSupported = false);
    }
  }

  Future<void> _toggleEdgeLighting(bool desired) async {
    if (_edgeLoading || !_edgeSupported) return;
    setState(() => _edgeLoading = true);
    try {
      if (desired && !_edgePermissionGranted) {
        _edgePendingEnable = true;
        final opened = await _edgeLightingChannel.invokeMethod<bool>(
          'openPermissionSettings');
        if (opened != true) {
          _edgePendingEnable = false;
          await _refreshEdgeLighting();
        }
        // Keep the pending choice until lifecycle resume after the user
        // returns from Android special-access settings.
      } else {
        await _edgeLightingChannel.invokeMethod<bool>(
          'setEnabled', {'enabled': desired});
        await _refreshEdgeLighting();
      }
    } on PlatformException {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Android could not open edge lighting settings.'),
        ));
      }
    } finally {
      if (mounted) setState(() => _edgeLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final nickname = ref.watch(localNicknameProvider) ?? '—';
    final screenshotBlockEnabled = ref.watch(screenshotBlockEnabledProvider);
    final screenPrivacyMode = ref.watch(screenPrivacyModeEnabledProvider);
    final biometricLockEnabled = ref.watch(biometricLockEnabledProvider);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.settingsTitle)),
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
          ListTile(
            leading: const Icon(
              Icons.shield_moon_outlined,
              color: StellarColors.accentBlue,
            ),
            title: const Text('Stellar Security'),
            subtitle: const Text('Learn how Stellar protects you'),
            trailing: const Icon(
              Icons.chevron_right,
              color: StellarColors.textSecondary,
            ),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const StellarSecurityScreen(),
                ),
              );
            },
          ),
          const Divider(color: StellarColors.bgElevated),

          ListTile(
            leading: const Icon(Icons.language, color: StellarColors.accentBlue),
            title: Text(l10n.language),
            subtitle: Text(
              '${l10n.followsDeviceLanguage}: ${_languageName(
                Localizations.localeOf(context).languageCode,
                l10n,
              )}',
            ),
          ),
          _SectionHeader(l10n.accountSection),
          ListTile(
            leading: const Icon(Icons.alternate_email, color: StellarColors.accentBlue),
            title: const Text('Nickname'),
            subtitle: Text(nickname),
          ),
          ListTile(
            leading: const Icon(Icons.account_circle_outlined, color: StellarColors.accentBlue),
            title: const Text('My Profile'),
            subtitle: const Text('View or change your profile photo'),
            trailing: const Icon(Icons.chevron_right, color: StellarColors.textSecondary),
            onTap: () {
              if (nickname == '—' || nickname.trim().isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Your profile is not ready yet.')),
                );
                return;
              }
              context.push('/profile/${Uri.encodeComponent(nickname.trim())}');
            },
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

          ListTile(
            leading: const Icon(
              Icons.shield_moon_outlined,
              color: StellarColors.accentPurple,
            ),
            title: const Text('Stellar GUARD'),
            subtitle: const Text('Secure Stellar user removal'),
            trailing: const Icon(
              Icons.chevron_right,
              color: StellarColors.textSecondary,
            ),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const StellarGuardScreen(),
                ),
              );
            },
          ),

          _SectionHeader(l10n.privacySection),
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

          _SectionHeader(l10n.chatsSection),
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

          _SectionHeader(l10n.appLockSection),
          SwitchListTile(
            activeColor: StellarColors.accentBlue,
            title: const Text('Biometric / PIN lock'),
            value: biometricLockEnabled,
            onChanged: (v) async {
              final controller = ref.read(appLockControllerProvider);

              if (v) {
                final enabled = await controller.enableBiometricLock();

                if (!mounted) return;

                if (enabled) {
                  ref.read(biometricLockEnabledProvider.notifier).state = true;
                } else {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Biometric authentication was not enabled.'),
                    ),
                  );
                }
              } else {
                final authenticated = await controller.authenticate();

                if (!mounted) return;

                if (!authenticated) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text(
                        'Biometric authentication required to disable the lock.',
                      ),
                    ),
                  );
                  return;
                }

                await controller.disableBiometricLock();

                if (!mounted) return;

                ref.read(biometricLockEnabledProvider.notifier).state = false;
              }
            },
          ),

          _SectionHeader(l10n.notificationsSection),
          if (Platform.isAndroid)
            SwitchListTile(
              activeColor: StellarColors.accentPurple,
              secondary: const Icon(Icons.auto_awesome,
                  color: StellarColors.accentPurple),
              title: const Text('Purple edge lighting'),
              subtitle: Text(!_edgeSupported
                  ? 'Requires Android 8 or later'
                  : !_edgePermissionGranted
                      ? 'Optional: grant Display over other apps to flash '
                        'the edges for background/locked-screen messages'
                      : 'Two gentle purple pulses; lock-screen display '
                        'depends on Android and device settings'),
              value: _edgeEnabled,
              onChanged: _edgeSupported && !_edgeLoading
                  ? _toggleEdgeLighting : null,
            ),
          ListTile(
            leading: const Icon(
              Icons.campaign_outlined,
              color: StellarColors.accentPurple,
            ),
            title: const Text('Broadcasts'),
            subtitle: const Text('Announcements and attached files'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/broadcasts'),
          ),
          ListTile(
            leading: const Icon(Icons.notifications_outlined, color: StellarColors.accentPurple),
            title: const Text('Preview level'),
            subtitle: Text(_notificationPreviewLevelLabel(_notificationPreviewLevel)),
            onTap: () => _showPreviewLevelPicker(context),
          ),

          _SectionHeader(l10n.aboutSection),
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

  Future<void> _confirmResetIdentity(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: StellarColors.bgElevated,
        title: const Text('Reset Identity?'),
        content: const Text(
          'This removes local messages, sessions, identity data, PIN settings, '
          'and local media. Your contacts will need to verify your new identity. '
          'This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text(
              'Reset',
              style: TextStyle(color: StellarColors.danger),
            ),
          ),
        ],
      ),
    );

    if (confirmed != true || !context.mounted) return;

    try {
      final db = ref.read(databaseProvider);
      final keyStore = ref.read(platformKeyStoreProvider);

      await ref.read(localNicknameProvider.notifier).clear();
      await db.clearAllLocalData();

      final support = await getApplicationSupportDirectory();
      for (final name in <String>['media', 'profile_photos']) {
        final directory = Directory('${support.path}/$name');
        if (await directory.exists()) {
          await directory.delete(recursive: true);
        }
      }

      await keyStore.wipeAllExceptDatabaseKey();

      ref.invalidate(chatRepositoryProvider);
      ref.invalidate(groupCryptoProvider);
      ref.invalidate(sessionManagerProvider);
      ref.invalidate(identityKeyStoreProvider);
      ref.invalidate(profilePhotoSyncServiceProvider);
      ref.invalidate(profilePhotoServiceProvider);
      ref.invalidate(mediaAttachmentServiceProvider);
      ref.read(isUnlockedProvider.notifier).state = false;

      if (context.mounted) context.go('/onboarding/welcome');
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Reset failed: $error')),
        );
      }
    } finally {
      if (mounted) {
        ref.read(isUnlockedProvider.notifier).state = false;
      }
    }
  }
}

String _languageName(String code, AppLocalizations l10n) {
  switch (code) {
    case 'mk':
      return l10n.languageMacedonian;
    case 'sq':
      return l10n.languageAlbanian;
    case 'ru':
      return l10n.languageRussian;
    default:
      return l10n.languageEnglish;
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
