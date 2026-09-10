import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/stellar_theme.dart';
import '../../../core/network/directory_client.dart';
import '../../state/app_providers.dart';

class ChooseNicknameScreen extends ConsumerStatefulWidget {
  const ChooseNicknameScreen({super.key});

  @override
  ConsumerState<ChooseNicknameScreen> createState() =>
      _ChooseNicknameScreenState();
}

class _ChooseNicknameScreenState
    extends ConsumerState<ChooseNicknameScreen> {
  final _controller = TextEditingController();

  String? _error;
  bool _checking = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final nickname = _controller.text.trim();

    if (nickname.isEmpty) {
      setState(() => _error = 'Please enter a nickname.');
      return;
    }

    if (nickname.length < 3) {
      setState(() => _error = 'Nickname must contain at least 3 characters.');
      return;
    }

    if (nickname.length > 32) {
      setState(() => _error = 'Nickname must contain at most 32 characters.');
      return;
    }

    if (!RegExp(r'^[a-zA-Z0-9_]+$').hasMatch(nickname)) {
      setState(
        () => _error =
            'Nickname can contain only letters, numbers and underscores.',
      );
      return;
    }

    setState(() {
      _checking = true;
      _error = null;
    });

    try {
      final directory = ref.read(directoryClientProvider);

      final available = await directory.checkAvailability(nickname);

      if (!available) {
        if (!mounted) return;

        setState(() {
          _checking = false;
          _error = 'This nickname is already taken.';
        });

        return;
      }

      final sessionManager = ref.read(sessionManagerProvider);

      final bundle =
          await sessionManager.buildLocalDirectoryBundle();

      await directory.register(
        nickname: nickname,
        preKeyBundle: bundle,
      );

      await ref
          .read(localNicknameProvider.notifier)
          .setNickname(nickname);

      if (!mounted) return;

      setState(() => _checking = false);
      context.go('/onboarding/recovery');
    } on DirectoryException catch (e) {
      if (!mounted) return;

      setState(() => _checking = false);

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Directory error (${e.statusCode}): ${e.message}',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;

      setState(() => _checking = false);

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Registration failed: $e'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: StellarColors.bgPrimary,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(
                Icons.alternate_email,
                color: StellarColors.accentPurple,
                size: 40,
              ),
              const SizedBox(height: 16),
              const Text(
                'Choose your @nickname',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'This is the only handle contacts use to find you — no phone number or email needed.',
                style: TextStyle(
                  color: StellarColors.textSecondary,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 24),
              TextField(
                controller: _controller,
                autofocus: true,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) {
                  if (!_checking) _submit();
                },
                decoration: InputDecoration(
                  prefixText: '@',
                  hintText: 'nickname',
                  errorText: _error,
                  border: const OutlineInputBorder(),
                ),
                onChanged: (_) {
                  if (_error != null) {
                    setState(() => _error = null);
                  }
                },
              ),
              const Spacer(),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _checking ? null : _submit,
                  child: _checking
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Text('Continue'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
