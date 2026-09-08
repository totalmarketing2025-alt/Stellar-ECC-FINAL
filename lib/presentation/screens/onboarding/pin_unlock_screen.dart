import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/stellar_theme.dart';
import '../../state/app_providers.dart';

class PinUnlockScreen extends ConsumerStatefulWidget {
  const PinUnlockScreen({super.key});

  @override
  ConsumerState<PinUnlockScreen> createState() => _PinUnlockScreenState();
}

class _PinUnlockScreenState extends ConsumerState<PinUnlockScreen> {
  final _pinController = TextEditingController();
  String? _error;
  bool _checking = false;

  Future<void> _unlock() async {
    final pin = _pinController.text;

    if (pin.length < 4) {
      setState(() => _error = 'Enter your PIN.');
      return;
    }

    setState(() {
      _checking = true;
      _error = null;
    });

    final keyStore = ref.read(platformKeyStoreProvider);
    final valid = await keyStore.verifyPin(pin);

    if (!mounted) return;

    if (valid) {
      ref.read(isUnlockedProvider.notifier).state = true;
      context.go('/chats');
    } else {
      setState(() {
        _checking = false;
        _error = 'Incorrect PIN.';
      });
      _pinController.clear();
    }
  }

  @override
  void dispose() {
    _pinController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: StellarColors.bgPrimary,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Spacer(),
              const Icon(
                Icons.lock_outline,
                color: StellarColors.accentBlue,
                size: 48,
              ),
              const SizedBox(height: 20),
              const Text(
                'Unlock Stellar ECC',
                style: TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 10),
              const Text(
                'Enter your PIN to access your messages.',
                style: TextStyle(
                  color: StellarColors.textSecondary,
                ),
              ),
              const SizedBox(height: 28),
              TextField(
                controller: _pinController,
                obscureText: true,
                keyboardType: TextInputType.number,
                maxLength: 6,
                autofocus: true,
                onSubmitted: (_) => _unlock(),
                decoration: InputDecoration(
                  labelText: 'PIN',
                  errorText: _error,
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _checking ? null : _unlock,
                  child: Text(_checking ? 'Checking...' : 'Unlock'),
                ),
              ),
              const Spacer(),
            ],
          ),
        ),
      ),
    );
  }
}
