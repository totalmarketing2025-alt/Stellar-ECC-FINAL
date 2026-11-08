import 'package:flutter/material.dart';
import '../../../core/theme/stellar_theme.dart';

class StellarSecurityScreen extends StatelessWidget {
  const StellarSecurityScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Stellar Security')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: const [
          _SecuritySection(
            icon: Icons.lock_outline,
            title: 'Message encryption',
            body: 'One-to-one conversations use the Signal Protocol '
                'and Double Ratchet encryption. Group conversations use '
                'Sender Keys. Message content is encrypted for the '
                'conversation participants. Some metadata may still be '
                'visible to network infrastructure.',
          ),
          _SecuritySection(
            icon: Icons.key_outlined,
            title: 'Protect your keys and account',
            body: 'Sensitive key material is stored using platform-protected '
                'secure storage. Use a strong app PIN and device screen lock. '
                'Never share your PIN and keep your device and Stellar updated.',
          ),
          _SecuritySection(
            icon: Icons.shield_outlined,
            title: 'Wanted Mode',
            body: 'Wanted Mode is an optional security feature that requires '
                'an app PIN. When enabled, it monitors selected local events '
                'in USB, Bluetooth, network and power categories. Certain '
                'events can create a security challenge. Follow the prompt '
                'and verify with your app PIN within the displayed time.',
          ),
          _SecuritySection(
            icon: Icons.info_outline,
            title: 'You stay in control',
            body: 'Detected events do not automatically wipe data or lock '
                'your account. You can choose Lock now to lock the app. '
                'Wipe local data and lock is a separate manual action. '
                'It clears local app data, but cannot erase copies held by '
                'other participants or guarantee deletion of remote data. '
                'Monitoring may be affected by device and operating-system '
                'limitations.',
          ),
          _SecuritySection(
            icon: Icons.verified_user_outlined,
            title: 'Security best practices',
            body: 'Keep your PIN private, lock your phone when unattended, '
                'install updates and verify contact safety information '
                'through a trusted channel when appropriate.',
          ),
          _SecuritySection(
            icon: Icons.business_outlined,
            title: 'About',
            body: 'Stellar is a product of I-WORKS North Macedonia.',
          ),
        ],
      ),
    );
  }
}

class _SecuritySection extends StatelessWidget {
  const _SecuritySection({
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: StellarColors.bgElevated,
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: StellarColors.accentBlue),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              body,
              style: const TextStyle(
                color: StellarColors.textSecondary,
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
