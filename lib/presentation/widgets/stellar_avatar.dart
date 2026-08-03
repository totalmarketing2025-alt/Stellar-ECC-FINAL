import 'package:flutter/material.dart';

import '../../core/theme/stellar_theme.dart';

/// Gradient monogram avatar — no forced profile photo requirement, per
/// the privacy-first identity model (Phase 1/5): a nickname is enough.
class StellarAvatar extends StatelessWidget {
  const StellarAvatar({super.key, required this.seed, required this.label, this.size = 44});

  final String seed;
  final String label;
  final double size;

  @override
  Widget build(BuildContext context) {
    final initial = label.isNotEmpty ? label[0].toUpperCase() : '?';
    return Container(
      width: size,
      height: size,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        gradient: StellarColors.stellarGradient,
      ),
      alignment: Alignment.center,
      child: Text(
        initial,
        style: TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w700,
          fontSize: size * 0.4,
        ),
      ),
    );
  }
}
