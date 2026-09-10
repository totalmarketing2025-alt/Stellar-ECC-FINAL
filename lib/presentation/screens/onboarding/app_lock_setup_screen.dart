import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/stellar_theme.dart';
import '../../state/app_providers.dart';
import '../../state/app_lock_controller.dart';

class AppLockSetupScreen extends ConsumerStatefulWidget {
  const AppLockSetupScreen({super.key});

  @override
  ConsumerState<AppLockSetupScreen> createState() => _AppLockSetupScreenState();
}

class _AppLockSetupScreenState extends ConsumerState<AppLockSetupScreen> {
  final _pinController = TextEditingController();
  final _confirmController = TextEditingController();

  String? _error;
  bool _saving = false;

  Future<void> _enableBiometrics() async {
    final controller = ref.read(appLockControllerProvider);
    final enabled = await controller.enableBiometricLock();

    if (!mounted) return;

    if (enabled) {
      ref.read(isUnlockedProvider.notifier).state = true;
      context.go('/chats');
    } else {
      setState(() => _error = 'Biometric authentication was not enabled.');
    }
  }

  Future<void> _savePin() async {
    final pin = _pinController.text;
    final confirm = _confirmController.text;

    if (pin.length < 4 || pin.length > 6) {
      setState(() => _error = 'PIN must contain 4 to 6 digits.');
      return;
    }

    if (!RegExp(r'^\d+$').hasMatch(pin)) {
      setState(() => _error = 'PIN must contain digits only.');
      return;
    }

    if (pin != confirm) {
      setState(() => _error = 'PINs do not match.');
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });

    final keyStore = ref.read(platformKeyStoreProvider);
    await keyStore.setPin(pin);

    if (!mounted) return;

    ref.read(isUnlockedProvider.notifier).state = true;
    context.go('/chats');
  }

  @override
  void dispose() {
    _pinController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          Image.asset(
            'assets/images/stellar_background.jpg',
            fit: BoxFit.cover,
          ),
          Container(
            color: Colors.black.withOpacity(0.58),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(
                Icons.lock_outline,
                color: StellarColors.accentBlue,
                size: 40,
              ),
              const SizedBox(height: 16),
              const Text(
                'Set your PIN',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'A PIN is required every time Stellar ECC is opened.',
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
                decoration: const InputDecoration(
                  labelText: 'PIN',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _confirmController,
                obscureText: true,
                keyboardType: TextInputType.number,
                maxLength: 6,
                onSubmitted: (_) => _savePin(),
                decoration: const InputDecoration(
                  labelText: 'Confirm PIN',
                  border: OutlineInputBorder(),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(
                  _error!,
                  style: const TextStyle(
                    color: StellarColors.danger,
                  ),
                ),
              ],
              const Spacer(),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _saving ? null : _savePin,
                  child: Text(_saving ? 'Saving...' : 'Set PIN'),
                ),
              ),

              const SizedBox(height: 12),

              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _saving ? null : _enableBiometrics,
                  icon: const Icon(Icons.fingerprint),
                  label: const Text('Enable biometric lock'),
                ),
              ),
            ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
