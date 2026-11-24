import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/security/account_recovery.dart';
import '../../../core/theme/stellar_theme.dart';
import '../../../l10n/stellar_translations.dart';
import '../../state/app_providers.dart';

class RecoverySetupScreen extends ConsumerStatefulWidget {
  const RecoverySetupScreen({super.key, this.isOnboarding = true});

  final bool isOnboarding;

  @override
  ConsumerState<RecoverySetupScreen> createState() => _RecoverySetupScreenState();
}

class _RecoverySetupScreenState extends ConsumerState<RecoverySetupScreen> {
  final _passphrase = TextEditingController();
  final _confirmation = TextEditingController();
  bool _working = false;

  @override
  void dispose() {
    _passphrase.dispose();
    _confirmation.dispose();
    super.dispose();
  }

  Future<void> _createRecoveryFile() async {
    if (_working) return;
    final passphrase = _passphrase.text;
    if (passphrase != _confirmation.text) {
      _showMessage(stellarText(context, 'Passphrases do not match.'));
      return;
    }
    if (passphrase.trim().length < 16) {
      _showMessage(stellarText(context, 'Use at least 16 characters for recovery.'));
      return;
    }
    final nickname = ref.read(localNicknameProvider)?.trim();
    if (nickname == null || nickname.isEmpty) {
      _showMessage(stellarText(context, 'Your profile is not ready yet.'));
      return;
    }
    setState(() => _working = true);
    try {
      final identityStore = ref.read(identityKeyStoreProvider);
      final backup = await AccountRecoveryService.createBackup(
        nickname: nickname,
        identityKeyPair: await identityStore.exportIdentityKeyPair(),
        registrationId: await identityStore.getLocalRegistrationId(),
        passphrase: passphrase,
      );
      final savedPath = await FilePicker.platform.saveFile(
        dialogTitle: stellarText(context, 'Save recovery file'),
        fileName: 'stellar-account-recovery.stellar',
        bytes: Uint8List.fromList(backup.fileBytes),
      );
      if (savedPath == null) return;
      await ref.read(platformKeyStoreProvider).writeSecret(
        accountRecoveryKeyAlias,
        backup.recoveryKey,
      );
      await ref.read(storiesServiceProvider).backfillOwnerRecovery(
        nickname: nickname,
        recoveryKey: backup.recoveryKey,
      );
      if (!mounted) return;
      _passphrase.clear();
      _confirmation.clear();
      _showMessage(stellarText(context,
          'Recovery file saved. Store the file and passphrase in separate safe places.'));
      _continue();
    } catch (error) {
      if (mounted) {
        _showMessage('${stellarText(context, 'Could not create recovery file:')} $error');
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  void _skip() => _continue();

  void _continue() {
    if (widget.isOnboarding) {
      ref.read(pinSetupRequiredProvider.notifier).state = true;
      context.go('/onboarding/app-lock');
    } else {
      context.pop();
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
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.backup_outlined,
                  color: StellarColors.accentPurple, size: 40),
              const SizedBox(height: 16),
              Text(stellarText(context, 'Account recovery'),
                  style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700)),
              const SizedBox(height: 12),
              Text(stellarText(context,
                'This encrypted file restores your account identity and Story keys. Chat history is not included.'),
                style: const TextStyle(color: StellarColors.textSecondary, height: 1.5)),
              const SizedBox(height: 8),
              Text(stellarText(context,
                'The recovery passphrase stays only on this device and is never sent to Stellar.'),
                style: const TextStyle(color: StellarColors.textSecondary, height: 1.5)),
              const SizedBox(height: 8),
              Text(stellarText(context,
                'Use at least 16 characters. Store the encrypted file and passphrase in separate safe places.'),
                style: const TextStyle(color: StellarColors.textSecondary, height: 1.5)),
              const SizedBox(height: 24),
              TextField(
                controller: _passphrase,
                obscureText: true,
                autofillHints: const [AutofillHints.newPassword],
                decoration: InputDecoration(
                  labelText: stellarText(context, 'Recovery passphrase'),
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _confirmation,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: stellarText(context, 'Confirm recovery passphrase'),
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _working ? null : _createRecoveryFile,
                  icon: _working
                      ? const SizedBox(width: 18, height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.save_alt),
                  label: Text(stellarText(context, 'Create encrypted recovery file')),
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: TextButton(
                  onPressed: _working ? null : _skip,
                  child: Text(stellarText(context, widget.isOnboarding
                      ? 'Skip for now' : 'Cancel')),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
