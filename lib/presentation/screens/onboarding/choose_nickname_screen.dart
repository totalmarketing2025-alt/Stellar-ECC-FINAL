import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/stellar_theme.dart';
import '../../state/app_providers.dart';
import '../../../core/network/directory_client.dart';

class ChooseNicknameScreen extends ConsumerStatefulWidget {
  const ChooseNicknameScreen({super.key});

  @override
  ConsumerState<ChooseNicknameScreen> createState() => _ChooseNicknameScreenState();
}

class _ChooseNicknameScreenState extends ConsumerState<ChooseNicknameScreen> {
  final _controller = TextEditingController();
  String? _error;
  bool _checking = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: StellarColors.bgPrimary,
      appBar: AppBar(backgroundColor: Colors.transparent, elevation: 0),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Choose your @nickname', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            const Text(
              'This is the only handle contacts use to find you — no phone number or email needed.',
              style: TextStyle(color: StellarColors.textSecondary),
            ),
            const SizedBox(height: 24),
            TextField(
              controller: _controller,
              autofocus: true,
              decoration: InputDecoration(
                prefixText: '@',
                hintText: 'nickname',
                errorText: _error,
              ),
              onChanged: (_) => setState(() => _error = null),
            ),
            const Spacer(),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _checking ? null : _submit,
                child: _checking
                    ? const SizedBox(
                        width: 20, height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : const Text('Continue'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _submit() async {
    final nickname = _controller.text.trim();

    if (nickname.isEmpty) {
      return;
    }

    setState(() => _checking = true);

    try {
      final directory = ref.read(directoryClientProvider);

      final available =
          await directory.checkAvailability(nickname);

      if (!available) {
        if (!mounted) return;

        setState(() => _checking = false);

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('This nickname is already taken.'),
          ),
        );

        return;
      }

      final sessionManager =
          ref.read(sessionManagerProvider);

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
}
