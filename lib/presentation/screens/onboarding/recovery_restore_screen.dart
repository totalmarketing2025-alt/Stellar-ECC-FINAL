import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/security/account_recovery.dart';
import '../../../core/theme/stellar_theme.dart';
import '../../../l10n/stellar_translations.dart';
import '../../state/app_providers.dart';

class RecoveryRestoreScreen extends ConsumerStatefulWidget {
  const RecoveryRestoreScreen({super.key});

  @override
  ConsumerState<RecoveryRestoreScreen> createState() => _RecoveryRestoreScreenState();
}

class _RecoveryRestoreScreenState extends ConsumerState<RecoveryRestoreScreen> {
  Uint8List? _backup;
  String? _fileName;
  final _passphrase = TextEditingController();
  bool _working = false;

  @override
  void dispose() {
    _passphrase.dispose();
    super.dispose();
  }

  Future<void> _chooseFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['stellar'],
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;
    final file = result.files.single;
    if (file.bytes == null) {
      _showMessage(stellarText(context, 'Could not read recovery file.'));
      return;
    }
    setState(() {
      _backup = file.bytes;
      _fileName = file.name;
    });
  }

  Future<void> _restore() async {
    if (ref.read(localNicknameProvider) != null) {
      _showMessage(stellarText(context, 'An account is already configured on this device.'));
      return;
    }
    final backup = _backup;
    if (backup == null) {
      _showMessage(stellarText(context, 'Select a recovery file first.'));
      return;
    }
    if (_working) return;
    setState(() => _working = true);
    try {
      final recovered = await AccountRecoveryService.openBackup(
        backup: backup,
        passphrase: _passphrase.text,
      );
      final identityStore = ref.read(identityKeyStoreProvider);
      await identityStore.restoreRecoveryIdentity(
        serializedIdentity: recovered.identityKeyPair,
        registrationId: recovered.registrationId,
      );
      await identityStore.initializeIfAbsent();
      await ref.read(platformKeyStoreProvider).writeSecret(
        accountRecoveryKeyAlias,
        recovered.recoveryKey,
      );
      await ref.read(localNicknameProvider.notifier).setNickname(recovered.nickname);
      ref.read(pinSetupRequiredProvider.notifier).state = true;
      _passphrase.clear();
      if (mounted) context.go('/onboarding/app-lock');
    } catch (error) {
      if (mounted) {
        _showMessage('${stellarText(context, 'Could not restore account:')} $error');
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  void _showMessage(String value) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(value)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: StellarColors.bgPrimary,
      appBar: AppBar(backgroundColor: Colors.transparent, elevation: 0),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.settings_backup_restore,
                  color: StellarColors.accentPurple, size: 40),
              const SizedBox(height: 16),
              Text(stellarText(context, 'Restore account'),
                  style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              Text(stellarText(context,
                'This restores your account identity and Story keys. Chat history is not included.'),
                style: const TextStyle(color: StellarColors.textSecondary, height: 1.5)),
              const SizedBox(height: 20),
              OutlinedButton.icon(
                onPressed: _working ? null : _chooseFile,
                icon: const Icon(Icons.folder_open),
                label: Text(_fileName ?? stellarText(context, 'Select recovery file')),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _passphrase,
                obscureText: true,
                autofillHints: const [AutofillHints.password],
                decoration: InputDecoration(
                  labelText: stellarText(context, 'Recovery passphrase'),
                  border: const OutlineInputBorder(),
                ),
              ),
              const Spacer(),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _working ? null : _restore,
                  icon: _working
                      ? const SizedBox(width: 18, height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.restore),
                  label: Text(stellarText(context, 'Restore')),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
