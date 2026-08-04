import 'package:flutter/material.dart';

class StellarColors {
  static const bgPrimary = Color(0xFF05060A);
  static const bgSurface = Color(0xFF0E1016);
  static const bgElevated = Color(0xFF161925);

  static const accentBlue = Color(0xFF4A7CFF);
  static const accentPurple = Color(0xFF8B5CF6);

  static const text = Color(0xFFF2F3F7);
  static const textPrimary = Color(0xFFF2F3F7);
  static const textSecondary = Color(0xFF8B8FA3);

  static const success = Color(0xFF34D399);
  static const danger = Color(0xFFF87171);

  static const stellarGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [
      accentBlue,
      accentPurple,
    ],
  );
}

class StellarTheme {
  static ThemeData dark() {
    return ThemeData(
      brightness: Brightness.dark,

      scaffoldBackgroundColor: StellarColors.bgPrimary,

      colorScheme: const ColorScheme.dark(
        primary: StellarColors.accentBlue,
        secondary: StellarColors.accentPurple,
      ),

      cardTheme: const CardTheme(
        color: StellarColors.bgElevated,
        elevation: 0,
      ),

      textTheme: const TextTheme(
        bodyLarge: TextStyle(
          color: StellarColors.text,
        ),
        bodyMedium: TextStyle(
          color: StellarColors.textSecondary,
        ),
      ),
    );
  }
}
