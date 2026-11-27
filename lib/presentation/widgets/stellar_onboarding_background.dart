import 'package:flutter/material.dart';

/// Shared full-screen artwork for the account onboarding and recovery flow.
class StellarOnboardingBackground extends StatelessWidget {
  const StellarOnboardingBackground({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        Image.asset(
          'assets/images/stellar_background.jpg',
          fit: BoxFit.cover,
        ),
        ColoredBox(color: Colors.black.withOpacity(0.58)),
        child,
      ],
    );
  }
}
