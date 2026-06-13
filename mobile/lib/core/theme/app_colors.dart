import 'package:flutter/material.dart';

/// THE palette. This is the ONLY file in the app allowed to contain hex
/// values. Everything else reads colors through ThemeData / AppColorsX.
abstract final class AppPalette {
  // Brand
  static const cream = Color(0xFFFFF8E7);
  static const amber = Color(0xFFF5A623);
  static const softPurple = Color(0xFF8B7FD4);
  static const coral = Color(0xFFE8645A);

  // Dark mode
  static const darkBg = Color(0xFF1A1A2E);
  static const darkSurface = Color(0xFF252540);
  static const darkCard = Color(0xFF2D2D4E);

  // Light mode
  static const lightCard = Color(0xFFFFFFFF);

  // Text
  static const textPrimaryLight = Color(0xFF1A1A2E);
  static const textPrimaryDark = Color(0xFFF0F0FF);
  static const textSecondaryLight = Color(0xFF6B6B80);
  static const textSecondaryDark = Color(0xFFA0A0C0);

  // Status (live dashboard / badges)
  static const statusActive = Color(0xFF4CAF7D);
  static const statusIdle = amber;
  static const statusOffline = Color(0xFF9E9EAE);
  static const statusGpsDisabled = coral;
  static const statusLowBattery = Color(0xFFE8A05A);

  // Shadows: soft, 8% opacity — never harsh Material elevation
  static const shadowLight = Color(0x141A1A2E); // 8% of darkBg
  static const shadowDark = Color(0x14000000);
}
