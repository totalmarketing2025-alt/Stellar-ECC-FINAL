import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/theme/stellar_theme.dart';

/// Small live-ticking ring showing remaining time-to-expiry for a message
/// or chat's oldest visible message (Phase 5 chat list / chat window
/// spec). Uses a single shared-per-instance Timer rather than a global
/// ticker; the chat window batches many of these, see the perf note in
/// docs/13-performance.md about avoiding per-bubble timer storms — for
/// very long visible lists, prefer driving this from a single parent
/// AnimatedBuilder instead of one Timer per tile.
class ExpiryRing extends StatefulWidget {
  const ExpiryRing({super.key, required this.expiresAt, this.size = 16, this.totalDuration});

  final DateTime expiresAt;
  final double size;
  final Duration? totalDuration;

  @override
  State<ExpiryRing> createState() => _ExpiryRingState();
}

class _ExpiryRingState extends State<ExpiryRing> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final remaining = widget.expiresAt.difference(DateTime.now());
    final total = widget.totalDuration ?? const Duration(hours: 1);
    final fraction = total.inSeconds == 0
        ? 0.0
        : (remaining.inSeconds / total.inSeconds).clamp(0.0, 1.0);

    final isUrgent = remaining.inSeconds < 60;

    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: CustomPaint(
        painter: _RingPainter(
          fraction: fraction,
          color: isUrgent ? StellarColors.danger : StellarColors.accentPurple,
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({required this.fraction, required this.color});
  final double fraction;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 1.5;

    final trackPaint = Paint()
      ..color = StellarColors.bgElevated
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    canvas.drawCircle(center, radius, trackPaint);

    final progressPaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;

    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -math.pi / 2,
      2 * math.pi * fraction,
      false,
      progressPaint,
    );
  }

  @override
  bool shouldRepaint(covariant _RingPainter oldDelegate) =>
      oldDelegate.fraction != fraction || oldDelegate.color != color;
}
