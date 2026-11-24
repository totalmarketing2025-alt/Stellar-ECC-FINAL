import 'package:flutter/material.dart';
import '../../../core/theme/stellar_theme.dart';
import '../../../l10n/stellar_translations.dart';

class StellarSecurityScreen extends StatelessWidget {
  const StellarSecurityScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(stellarText(context, "Stellar Security"))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _SecuritySection(
            icon: Icons.lock_outline,
            title: stellarText(context, "Message encryption"),
            body: 'One-to-one conversations use the Signal Protocol '
                'and Double Ratchet encryption. Group conversations use '
                'Sender Keys. Message content is encrypted for the '
                'conversation participants. Some metadata may still be '
                'visible to network infrastructure.',
          ),
          _SecuritySection(
            icon: Icons.key_outlined,
            title: stellarText(context, "Protect your keys and account"),
            body: 'Sensitive key material is stored using platform-protected '
                'secure storage. Use a strong app PIN and device screen lock. '
                'Never share your PIN and keep your device and Stellar updated.',
          ),
          _SecuritySection(
            icon: Icons.shield_outlined,
            title: stellarText(context, "Wanted Mode"),
            body: stellarText(context, "When enabled, Wanted Mode watches supported USB host devices, Bluetooth, Wi-Fi and power changes. Each detected event creates a 10-second app PIN check. If it expires while Wanted Mode alerts are allowed, Stellar wipes this phone's local app data and locks the app. If Android blocks the alerts, the check remains listed as expired for PIN review instead of causing an automatic wipe. A battery check starts below 20% and rearms at 25%."),
          ),
          _SecuritySection(
            icon: Icons.info_outline,
            title: stellarText(context, "You stay in control"),
            body: stellarText(context, "Lock now only locks the app. Wipe local data and lock erases this phone's Stellar messages, media, profile data and identity secrets. It cannot erase copies already delivered to other devices."),
          ),
          _SecuritySection(
            icon: Icons.report_gmailerrorred_outlined,
            title: stellarText(context, "Stellar GUARD"),
            body: stellarText(context, "Stellar GUARD lets you report an account using its nine-digit Guard code. The code identifies the account; it is not your app PIN. Reports for harassment, threats, scams, impersonation and other reasons go to moderators. Submitting one does not disable the account immediately; moderators may take action after review."),
          ),
          _SecuritySection(
            icon: Icons.warning_amber_rounded,
            title: stellarText(context, "Theft reports"),
            body: stellarText(context, "Theft reports are different in the current server setup: if the code matches an active account, the server revokes that account automatically, without moderator review. A code match identifies the account; it does not prove theft. Check the code carefully. This action cannot be reversed in Stellar."),
          ),
          _SecuritySection(
            icon: Icons.history,
            title: stellarText(context, "Report records and limits"),
            body: stellarText(context, "GUARD reports and audit history are retained for review. Local case references may be lost if you wipe app data. GUARD cannot erase messages already delivered to other devices."),
          ),
          _SecuritySection(
            icon: Icons.verified_user_outlined,
            title: stellarText(context, "Security best practices"),
            body: 'Keep your PIN private, lock your phone when unattended, '
                'install updates and verify contact safety information '
                'through a trusted channel when appropriate.',
          ),
          _SecuritySection(
            icon: Icons.business_outlined,
            title: stellarText(context, "About"),
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
