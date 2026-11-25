import 'package:flutter/material.dart';

import '../../core/theme/stellar_theme.dart';
import '../../l10n/stellar_translations.dart';

class AttachmentViewPolicy {
  const AttachmentViewPolicy(this.mode, this.seconds);

  const AttachmentViewPolicy.normal() : this('normal', 0);
  const AttachmentViewPolicy.viewOnce() : this('view_once', 0);
  const AttachmentViewPolicy.timed(int seconds) : this('timed', seconds);

  final String mode;
  final int seconds;
}

class AttachmentViewPolicySheet extends StatelessWidget {
  const AttachmentViewPolicySheet({super.key});

  @override
  Widget build(BuildContext context) {
    final options = <(String, AttachmentViewPolicy, IconData)>[
      (stellarText(context, 'Keep in chat'), const AttachmentViewPolicy.normal(), Icons.image_outlined),
      (stellarText(context, 'View once'), const AttachmentViewPolicy.viewOnce(), Icons.visibility_off_outlined),
      (stellarText(context, 'View for 10 seconds'), const AttachmentViewPolicy.timed(10), Icons.timer_outlined),
      (stellarText(context, 'View for 30 seconds'), const AttachmentViewPolicy.timed(30), Icons.timer_outlined),
      (stellarText(context, 'View for 1 minute'), const AttachmentViewPolicy.timed(60), Icons.timer_outlined),
    ];
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    stellarText(context, 'Choose how long this media can be viewed'),
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    stellarText(context, 'The recipient may still capture the screen with another device.'),
                    style: const TextStyle(
                      color: StellarColors.textSecondary,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            for (final (label, policy, icon) in options)
              ListTile(
                leading: Icon(icon, color: StellarColors.accentBlue),
                title: Text(label),
                onTap: () => Navigator.pop(context, policy),
              ),
          ],
        ),
      ),
    );
  }
}
