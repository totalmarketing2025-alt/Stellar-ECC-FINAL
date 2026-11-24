import 'package:flutter/material.dart';

import '../../core/theme/stellar_theme.dart';

class TypingIndicator extends StatefulWidget {
  const TypingIndicator({super.key, required this.label});

  final String label;

  @override
  State<TypingIndicator> createState() => _TypingIndicatorState();
}

class _TypingIndicatorState extends State<TypingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.fromLTRB(16, 4, 16, 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: StellarColors.bgElevated.withOpacity(0.94),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: StellarColors.accentPurple.withOpacity(0.4)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              widget.label,
              style: const TextStyle(
                color: StellarColors.textSecondary,
                fontSize: 12,
              ),
            ),
            const SizedBox(width: 8),
            for (var index = 0; index < 4; index++) ...[
              _TypingDot(controller: _controller, index: index),
              if (index != 3) const SizedBox(width: 3),
            ],
          ],
        ),
      ),
    );
  }
}

class _TypingDot extends StatelessWidget {
  const _TypingDot({required this.controller, required this.index});

  final AnimationController controller;
  final int index;

  @override
  Widget build(BuildContext context) {
    final start = index * 0.12;
    final animation = CurvedAnimation(
      parent: controller,
      curve: Interval(
        start,
        (start + 0.55).clamp(0.0, 1.0),
        curve: Curves.easeInOut,
      ),
    );
    return FadeTransition(
      opacity: Tween<double>(begin: 0.3, end: 1).animate(animation),
      child: ScaleTransition(
        scale: Tween<double>(begin: 0.75, end: 1.15).animate(animation),
        child: const DecoratedBox(
          decoration: BoxDecoration(
            color: StellarColors.accentPurple,
            shape: BoxShape.circle,
          ),
          child: SizedBox(width: 5, height: 5),
        ),
      ),
    );
  }
}
