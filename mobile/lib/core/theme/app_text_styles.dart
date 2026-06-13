import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Inter type scale. Styles carry NO color — color comes from the theme at
/// use-site (`AppTextStyles.body.copyWith(color: ...)` happens inside
/// ThemeData, not in screens), so one set of constants serves both modes.
abstract final class AppTextStyles {
  static final display = GoogleFonts.inter(
    fontWeight: FontWeight.w700,
    fontSize: 28,
    height: 1.2,
  );

  static final heading = GoogleFonts.inter(
    fontWeight: FontWeight.w600,
    fontSize: 20,
    height: 1.25,
  );

  static final body = GoogleFonts.inter(
    fontWeight: FontWeight.w400,
    fontSize: 14,
    height: 1.45,
  );

  static final bodyMedium = GoogleFonts.inter(
    fontWeight: FontWeight.w500,
    fontSize: 14,
    height: 1.45,
  );

  static final caption = GoogleFonts.inter(
    fontWeight: FontWeight.w400,
    fontSize: 12,
    height: 1.35,
  );

  static final button = GoogleFonts.inter(
    fontWeight: FontWeight.w600,
    fontSize: 15,
    height: 1.2,
  );
}
