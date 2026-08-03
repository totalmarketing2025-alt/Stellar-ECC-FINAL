import 'package:flutter/material.dart';

/// Design tokens from the Phase 5 UI/UX spec — "Deep Space" theme.
class StellarColors {
  static const bgPrimary = Color(0xFF05060A);
  static const bgSurface = Color(0xFF0E1016);
  static const bgElevated = Color(0xFF161925);
  static const accentBlue = Color(0xFF4A7CFF);
  static const accentPurple = Color(0xFF8B5CF6);
  static const textPrimary = Color(0xFFF2F3F7);
  static const textSecondary = Color(0xFF8B8FA3);
  static const success = Color(0xFF34D399);
  static const danger = Color(0xFFF87171);

  static const stellarGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [accentBlue, accentPurple],
  );
}

class StellarTheme {
  static ThemeData dark() {
    final base = ThemeData.dark(useMaterial3: true);

    return base.copyWith(
      scaffoldBackgroundColor: StellarColors.bgPrimary,
      colorScheme: base.colorScheme.copyWith(
        brightness: Brightness.dark,
        primary: StellarColors.accentBlue,
        secondary: StellarColors.accentPurple,
        surface: StellarColors.bgSurface,
        error: StellarColors.danger,
        onPrimary: StellarColors.textPrimary,
        onSurface: StellarColors.textPrimary,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: StellarColors.bgElevated,
        foregroundColor: StellarColors.textPrimary,
        elevation: 0,
        centerTitle: false,
      ),
      textTheme: base.textTheme.apply(
        bodyColor: StellarColors.textPrimary,
        displayColor: StellarColors.textPrimary,
      ).copyWith(
        bodySmall: base.textTheme.bodySmall?.copyWith(color: StellarColors.textSecondary),
      ),
      cardTheme: const CardThemeData(
        color: StellarColors.bgSurface,
        elevation: 0,
        margin: EdgeInsets.zero,
      ),
      dividerColor: StellarColors.bgElevated,
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: StellarColors.accentBlue,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: StellarColors.bgSurface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        hintStyle: const TextStyle(color: StellarColors.textSecondary),
      ),
    );
  }
}
