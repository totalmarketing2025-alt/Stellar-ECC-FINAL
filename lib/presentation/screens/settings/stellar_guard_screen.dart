import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../core/theme/stellar_theme.dart';

class StellarGuardScreen extends StatelessWidget {
  const StellarGuardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Stellar GUARD')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Icon(
            Icons.shield_moon_outlined,
            size: 56,
            color: StellarColors.accentBlue,
          ),
          const SizedBox(height: 16),
          const Text(
            'Stellar GUARD',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          const Text(
            'A secure process for requesting the removal of a Stellar user.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: StellarColors.textSecondary,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 24),
          Card(
            color: StellarColors.bgElevated,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Target user code',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    keyboardType: TextInputType.number,
                    maxLength: 9,
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(9),
                    ],
                    decoration: const InputDecoration(
                      hintText: 'Enter 9-digit code',
                      border: OutlineInputBorder(),
                      counterText: '',
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.info_outline,
                        color: StellarColors.accentBlue,
                      ),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Server verification and account-removal '
                          'protection are not implemented yet. No account '
                          'can be removed from this screen at this stage.',
                          style: TextStyle(
                            color: StellarColors.textSecondary,
                            height: 1.4,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: null,
                      child: const Text('Continue — coming soon'),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'Stellar GUARD will require server-side identity verification, '
            'authorization checks and abuse protection before any removal '
            'request can be processed.',
            style: TextStyle(
              color: StellarColors.textSecondary,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}
