import 'package:flutter/material.dart';

import '../../core/theme/stellar_theme.dart';
import '../../domain/models/chat.dart';

class TtlPickerSheet extends StatelessWidget {
  const TtlPickerSheet({super.key, required this.current, required this.title});
  final int current;
  final String title;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
            const SizedBox(height: 12),
            ...TtlPreset.all.map((seconds) => RadioListTile<int>(
                  value: seconds,
                  groupValue: current,
                  activeColor: StellarColors.accentBlue,
                  title: Text(TtlPreset.label(seconds)),
                  onChanged: (value) => Navigator.pop(context, value),
                )),
          ],
        ),
      ),
    );
  }
}
