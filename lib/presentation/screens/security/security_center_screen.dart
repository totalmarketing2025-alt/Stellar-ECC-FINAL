import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/stellar_theme.dart';
import '../../../core/crypto/fingerprint_formatter.dart';
import '../../../domain/models/chat.dart';
import '../../state/app_providers.dart';
import '../../state/security_providers.dart';
import '../../widgets/stellar_avatar.dart';

class SecurityCenterScreen extends ConsumerWidget {
  const SecurityCenterScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final score = ref.watch(securityScoreProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Security Center')),
      body: ListView(
        children: [
          _ScoreCard(score: score),

          _SectionHeader('Devices & Sessions'),
          ListTile(
            leading: const Icon(Icons.devices_other, color: StellarColors.accentBlue),
            title: const Text('Active devices'),
            subtitle: Consumer(
              builder: (context, ref, _) {
                final devices = ref.watch(linkedDevicesProvider);
                return Text('${devices.length} device${devices.length == 1 ? '' : 's'} linked');
              },
            ),
            trailing: const Icon(Icons.chevron_right, color: StellarColors.textSecondary),
            onTap: () => _openActiveDevices(context),
          ),
          ListTile(
            leading: const Icon(Icons.sync_alt, color: StellarColors.accentBlue),
            title: const Text('Session management'),
            subtitle: const Text('Double Ratchet sessions with your contacts'),
            trailing: const Icon(Icons.chevron_right, color: StellarColors.textSecondary),
            onTap: () => _openSessionManagement(context),
          ),

          _SectionHeader('Verification'),
          ListTile(
            leading: const Icon(Icons.qr_code_2, color: StellarColors.accentPurple),
            title: const Text('Verify contacts (QR code)'),
            subtitle: const Text('Compare fingerprints in person to confirm no interception'),
            trailing: const Icon(Icons.chevron_right, color: StellarColors.textSecondary),
            onTap: () => _openQrVerify(context),
          ),
          ListTile(
            leading: const Icon(Icons.fingerprint, color: StellarColors.accentPurple),
            title: const Text('Encryption key fingerprint'),
            subtitle: const Text('Your identity key, as a comparable number'),
            trailing: const Icon(Icons.chevron_right, color: StellarColors.textSecondary),
            onTap: () => _openFingerprint(context),
          ),

          _SectionHeader('Emergency'),
          ListTile(
            leading: const Icon(Icons.emergency_outlined, color: StellarColors.danger),
            title: const Text('Wanted Mode'),
            subtitle: const Text('Lock the app or erase its local data'),
            trailing: const Icon(Icons.chevron_right, color: StellarColors.textSecondary),
            onTap: () => _openWantedMode(context, ref),
          ),

          _SectionHeader('Backup & Privacy'),
          Consumer(
            builder: (context, ref, _) {
              final backupEnabled = ref.watch(cloudBackupEnabledProvider);
              return ListTile(
                leading: Icon(
                  backupEnabled ? Icons.cloud_outlined : Icons.cloud_off,
                  color: backupEnabled ? StellarColors.danger : StellarColors.success,
                ),
                title: const Text('Secure backup status'),
                subtitle: Text(
                  backupEnabled
                      ? 'Recovery backup is enabled'
                      : 'No cloud backup — messages exist only on this device',
                ),
              );
            },
          ),
          ListTile(
            leading: const Icon(Icons.privacy_tip_outlined, color: StellarColors.textSecondary),
            title: const Text('Privacy settings'),
            subtitle: const Text('Screenshot blocking, screen privacy, notification previews'),
            trailing: const Icon(Icons.chevron_right, color: StellarColors.textSecondary),
            onTap: () => context.push('/settings'),
          ),
        ],
      ),
    );
  }

  void _openActiveDevices(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: StellarColors.bgElevated,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      isScrollControlled: true,
      builder: (_) => const _ActiveDevicesSheet(),
    );
  }

  void _openSessionManagement(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: StellarColors.bgElevated,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      isScrollControlled: true,
      builder: (_) => const _SessionManagementSheet(),
    );
  }

  void _openQrVerify(BuildContext context) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => const _QrVerifyScreen()));
  }

  void _openFingerprint(BuildContext context) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => const _FingerprintScreen()));
  }

  void _openWantedMode(BuildContext context, WidgetRef ref) {
    showModalBottomSheet(
      context: context,
      backgroundColor: StellarColors.bgElevated,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => const _WantedModeSheet(),
    );
  }
}

class _ScoreCard extends StatelessWidget {
  const _ScoreCard({required this.score});
  final int score;

  Color get _color {
    if (score >= 80) return StellarColors.success;
    if (score >= 50) return StellarColors.accentPurple;
    return StellarColors.danger;
  }

  String get _label {
    if (score >= 80) return 'Strong';
    if (score >= 50) return 'Moderate';
    return 'Needs attention';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.all(16),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: StellarColors.bgSurface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _color.withOpacity(0.4)),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 64,
            height: 64,
            child: Stack(
              alignment: Alignment.center,
              children: [
                CircularProgressIndicator(
                  value: score / 100,
                  strokeWidth: 6,
                  backgroundColor: StellarColors.bgElevated,
                  valueColor: AlwaysStoppedAnimation(_color),
                ),
                Text('$score', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
              ],
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Security score', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
                const SizedBox(height: 4),
                Text(_label, style: TextStyle(color: _color)),
              ],
            ),
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

class _ActiveDevicesSheet extends ConsumerWidget {
  const _ActiveDevicesSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final devices = ref.watch(linkedDevicesProvider);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Active devices', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
            const SizedBox(height: 12),
            ...devices.map((d) => ListTile(
                  leading: Icon(
                    d.isCurrentDevice ? Icons.smartphone : Icons.devices,
                    color: StellarColors.accentBlue,
                  ),
                  title: Text(d.label),
                  subtitle: Text(d.isCurrentDevice
                      ? 'Active now'
                      : 'Last active ${d.lastActive.toLocal()}'),
                  trailing: d.isCurrentDevice
                      ? null
                      : TextButton(
                          onPressed: () {},
                          child: const Text('Revoke', style: TextStyle(color: StellarColors.danger)),
                        ),
                )),
            const SizedBox(height: 8),
            const Text(
              'Stellar ECC is single-device by design — this list will show '
              'additional linked devices once multi-device support ships.',
              style: TextStyle(color: StellarColors.textSecondary, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

class _SessionManagementSheet extends ConsumerWidget {
  const _SessionManagementSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chatsAsync = ref.watch(chatListProvider);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Session management', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
            const SizedBox(height: 4),
            const Text(
              'Each contact has an independent Double Ratchet session. '
              'Resetting one forces a fresh key exchange on your next message.',
              style: TextStyle(color: StellarColors.textSecondary, fontSize: 12),
            ),
            const SizedBox(height: 12),
            chatsAsync.when(
              loading: () => const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (_, __) => const Text('Could not load sessions', style: TextStyle(color: StellarColors.danger)),
              data: (chats) {
                final direct = chats.where((c) => c.chatType == ChatType.direct).toList();
                if (direct.isEmpty) {
                  return const Text('No active sessions yet', style: TextStyle(color: StellarColors.textSecondary));
                }
                return Column(
                  children: direct
                      .map((chat) => ListTile(
                            leading: StellarAvatar(seed: chat.chatId, label: chat.displayName, size: 36),
                            title: Text(chat.displayName),
                            subtitle: const Text('Session active'),
                            trailing: TextButton(
                              onPressed: () {},
                              child: const Text('Reset', style: TextStyle(color: StellarColors.danger)),
                            ),
                          ))
                      .toList(),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _QrVerifyScreen extends ConsumerWidget {
  const _QrVerifyScreen();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nickname = ref.watch(localNicknameProvider) ?? 'unknown';

    return Scaffold(
      appBar: AppBar(title: const Text('Verify Contact')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            const Text(
              'Have your contact scan this code, or scan theirs, to confirm '
              'you\'re both talking to who you think you are.',
              textAlign: TextAlign.center,
              style: TextStyle(color: StellarColors.textSecondary),
            ),
            const SizedBox(height: 24),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
              child: QrImageView(
                // Real payload would embed the identity public key bytes,
                // not just the nickname — kept to nickname here since the
                // identity key export format is decided alongside the
                // recovery/export flow (Phase 5 onboarding) rather than
                // duplicated ad hoc here.
                data: 'stellar-ecc://verify/$nickname',
                size: 220,
                backgroundColor: Colors.white,
              ),
            ),
            const SizedBox(height: 24),
            OutlinedButton.icon(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const _QrScanScreen()),
              ),
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('Scan a code instead'),
            ),
          ],
        ),
      ),
    );
  }
}

class _QrScanScreen extends StatelessWidget {
  const _QrScanScreen();

  @override
  Widget build(BuildContext context) {
    // Uses mobile_scanner's MobileScanner widget in a real build; kept as
    // a thin screen here so the camera-permission-gated widget has an
    // obvious single place to live once wired to an actual verification
    // result callback (compare scanned fingerprint against the local
    // session's safety number, then mark StellarIdentityKeyStore's
    // trusted-identity record as user-verified).
    return Scaffold(
      appBar: AppBar(title: const Text('Scan Code')),
      body: const Center(
        child: Text('Camera scanner view', style: TextStyle(color: StellarColors.textSecondary)),
      ),
    );
  }
}

class _FingerprintScreen extends ConsumerWidget {
  const _FingerprintScreen();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('Encryption Key Fingerprint')),
      body: FutureBuilder(
        future: ref.read(identityKeyStoreProvider).getIdentityKeyPair(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final identityPair = snapshot.data!;
          final fingerprint = FingerprintFormatter.forIdentityKey(identityPair.getPublicKey());

          return Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'This number uniquely identifies your encryption key. '
                  'It changes only if you reset your identity.',
                  style: TextStyle(color: StellarColors.textSecondary),
                ),
                const SizedBox(height: 20),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: StellarColors.bgSurface,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    fingerprint,
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 16, height: 1.6),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _WantedModeSheet extends ConsumerStatefulWidget {
  const _WantedModeSheet();

  @override
  ConsumerState<_WantedModeSheet> createState() => _WantedModeSheetState();
}

class _WantedModeSheetState extends ConsumerState<_WantedModeSheet>
    with WidgetsBindingObserver {
  bool _updatingMonitor = false;
  bool _checkingChallenges = false;
  bool _challengeDialogOpen = false;
  bool _challengeStoreCorrupted = false;
  bool _challengeStoreStatusUnknown = false;
  Timer? _challengePollTimer;
  final Set<String> _shownChallengeIds = <String>{};
  List<Map<String, dynamic>> _pendingChallenges = [];
  List<Map<String, dynamic>> _expiredChallenges = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refreshChallenges();
    _challengePollTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _refreshChallenges(),
    );
  }

  @override
  void dispose() {
    _challengePollTimer?.cancel();
    _challengePollTimer = null;
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refreshChallenges();
    }
  }

  Future<void> _refreshChallenges() async {
    if (_checkingChallenges || !mounted) return;

    _checkingChallenges = true;
    try {
      final notifier = ref.read(wantedModeWipeEnabledProvider.notifier);
      final corrupted = await notifier.isChallengeStoreCorrupted();

      final pending = corrupted
          ? <Map<String, dynamic>>[]
          : await notifier.getPendingChallenges();
      final expired = corrupted
          ? <Map<String, dynamic>>[]
          : await notifier.getExpiredChallenges();

      if (!mounted) return;

      setState(() {
        _challengeStoreCorrupted = corrupted;
        _challengeStoreStatusUnknown = false;
        _pendingChallenges = pending;
        _expiredChallenges = expired;
      });

      if (!corrupted && !_challengeDialogOpen && !_resolvingChallenge) {
        Map<String, dynamic>? nextChallenge;

        for (final challenge in pending) {
          final id = challenge['id']?.toString();
          if (id != null &&
              id.isNotEmpty &&
              !_shownChallengeIds.contains(id)) {
            nextChallenge = challenge;
            break;
          }
        }

        if (nextChallenge != null) {
          final challengeToShow = nextChallenge;
          final id = challengeToShow['id']?.toString();
          if (id != null) _shownChallengeIds.add(id);

          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              _showChallengePinDialog(challengeToShow);
            }
          });
        }
      }
    } catch (_) {
      // Preserve the last known challenge data and explicitly show unknown status.
      if (mounted) {
        setState(() => _challengeStoreStatusUnknown = true);
      }
    } finally {
      _checkingChallenges = false;
    }
  }

  bool _resolvingChallenge = false;

  Future<void> _showChallengePinDialog(
    Map<String, dynamic> challenge,
  ) async {
    if (_resolvingChallenge || _challengeDialogOpen || !mounted) {
      return;
    }

    final id = challenge['id']?.toString();
    if (id == null || id.isEmpty) return;

    _shownChallengeIds.add(id);
    _challengeDialogOpen = true;
    final controller = TextEditingController();

    try {
      final enteredPin = await showDialog<String>(
        context: context,
        barrierDismissible: true,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Verify Wanted Mode event'),
          content: TextField(
            controller: controller,
            autofocus: true,
            obscureText: true,
            keyboardType: TextInputType.number,
            enableSuggestions: false,
            autocorrect: false,
            decoration: InputDecoration(
              labelText: 'Existing app PIN',
              helperText:
                  '${challenge['category']} — ${challenge['action']}',
            ),
            onSubmitted: (value) =>
                Navigator.of(dialogContext).pop(value),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.of(dialogContext).pop(controller.text),
              child: const Text('Verify'),
            ),
          ],
        ),
      );

      if (!mounted || enteredPin == null) return;

      setState(() => _resolvingChallenge = true);

      final resolved = await ref
          .read(wantedModeWipeEnabledProvider.notifier)
          .resolveChallengeAfterPin(id: id, pin: enteredPin);

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            resolved
                ? 'Event verified. Wanted Mode remains active.'
                : 'PIN incorrect or the 10-second deadline has expired.',
          ),
        ),
      );

      await _refreshChallenges();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not verify this event.'),
          ),
        );
      }
    } finally {
      controller.dispose();
      _challengeDialogOpen = false;
      if (mounted) {
        setState(() => _resolvingChallenge = false);
        _refreshChallenges();
      }
    }
  }

  Future<void> _setMonitoring(bool enabled) async {
    if (_updatingMonitor) return;

    // Enabling Wanted Mode requires the existing app PIN.
    // Disabling it does not ask for a PIN.
    if (enabled) {
      final keyStore = ref.read(platformKeyStoreProvider);

      if (!await keyStore.hasPin()) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Set an app PIN before enabling Wanted Mode.',
              ),
            ),
          );
        }
        return;
      }

      final controller = TextEditingController();

      final enteredPin = await showDialog<String>(
        context: context,
        barrierDismissible: true,
        builder: (dialogContext) {
          return AlertDialog(
            title: const Text('Confirm app PIN'),
            content: TextField(
              controller: controller,
              autofocus: true,
              obscureText: true,
              keyboardType: TextInputType.number,
              enableSuggestions: false,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'Existing app PIN',
              ),
              onSubmitted: (value) {
                Navigator.of(dialogContext).pop(value);
              },
            ),
            actions: [
              TextButton(
                onPressed: () =>
                    Navigator.of(dialogContext).pop(),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(dialogContext)
                    .pop(controller.text),
                child: const Text('Confirm'),
              ),
            ],
          );
        },
      );

      controller.dispose();

      if (!mounted || enteredPin == null) return;

      final validPin = await keyStore.verifyPin(enteredPin);

      if (!validPin) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Incorrect PIN. Wanted Mode was not enabled.',
              ),
            ),
          );
        }
        return;
      }
    }

    if (!mounted) return;

    setState(() {
      _updatingMonitor = true;
    });

    try {
      await ref
          .read(wantedModeWipeEnabledProvider.notifier)
          .setEnabled(enabled);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              enabled
                  ? 'Could not enable Wanted Mode monitoring.'
                  : 'Could not stop Wanted Mode monitoring.',
            ),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _updatingMonitor = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final wipeEnabled = ref.watch(wantedModeWipeEnabledProvider);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Wanted Mode', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
            const SizedBox(height: 8),
            const Text(
              'Instantly locks the app, requiring biometric/PIN re-entry to reopen.',
              style: TextStyle(color: StellarColors.textSecondary),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                icon: const Icon(Icons.lock),
                label: const Text('Lock now'),
                onPressed: () {
                  ref.read(wantedModeControllerProvider).lockNow();
                  Navigator.pop(context);
                },
              ),
            ),
            const Divider(height: 32, color: StellarColors.bgElevated),
            if (_challengeStoreCorrupted)
              Card(
                child: ListTile(
                  leading: const Icon(
                    Icons.error,
                    color: StellarColors.danger,
                  ),
                  title: const Text('PIN challenge storage is corrupted'),
                  subtitle: const Text(
                    'Wanted Mode event verification is blocked. '
                    'Do not rely on monitoring until this issue is safely recovered.',
                  ),
                ),
              ),
            if (_challengeStoreStatusUnknown)
              Card(
                child: ListTile(
                  leading: const Icon(
                    Icons.warning_amber_rounded,
                    color: StellarColors.danger,
                  ),
                  title: const Text('Could not verify PIN storage status'),
                  subtitle: const Text(
                    'The native status check failed. The storage must not be '
                    'assumed healthy.',
                  ),
                ),
              ),
            if (_pendingChallenges.isNotEmpty) ...[
              const Text(
                'Pending event PIN checks',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              for (final challenge in _pendingChallenges)
                Card(
                  child: ListTile(
                    leading: const Icon(
                      Icons.warning_amber_rounded,
                      color: StellarColors.danger,
                    ),
                    title: Text(
                      '${challenge['category']} ${challenge['action']}',
                    ),
                    subtitle: const Text('Enter your app PIN within 10 seconds'),
                    trailing: const Icon(Icons.lock_outline),
                    onTap: _resolvingChallenge
                        ? null
                        : () => _showChallengePinDialog(challenge),
                  ),
                ),
            ],
            if (_expiredChallenges.isNotEmpty) ...[
              const SizedBox(height: 8),
              Card(
                child: ListTile(
                  leading: const Icon(
                    Icons.error_outline,
                    color: StellarColors.danger,
                  ),
                  title: Text(
                    '${_expiredChallenges.length} expired event PIN check(s)',
                  ),
                  subtitle: const Text(
                    'These events were not verified. Do not dismiss this warning.',
                  ),
                ),
              ),
            ],
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: _checkingChallenges ? null : _refreshChallenges,
                icon: const Icon(Icons.refresh),
                label: const Text('Refresh event checks'),
              ),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              activeColor: StellarColors.danger,
              title: const Text('Enable Wanted Mode wipe'),
              subtitle: const Text(
                'Enables local event monitoring and the manual local wipe action.',
              ),
              value: wipeEnabled,
              onChanged: _updatingMonitor ? null : _setMonitoring,
            ),
            if (wipeEnabled)
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(foregroundColor: StellarColors.danger, side: const BorderSide(color: StellarColors.danger)),
                  icon: const Icon(Icons.delete_forever),
                  label: const Text('Wipe local data and lock'),
                  onPressed: () => _wipeNow(context),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _wipeNow(BuildContext context) async {
    await ref.read(wantedModeControllerProvider).wipeAndLock();
    if (context.mounted) {
      Navigator.pop(context);
    }
  }

}
