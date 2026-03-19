import 'package:flutter/material.dart';

/// App border radius constants
/// Provides consistent border radius values across the application
class AppRadius {
  AppRadius._();

  static const double xs = 4.0;
  static const double sm = 8.0;
  static const double md = 12.0;
  static const double lg = 16.0;
  static const double xl = 20.0;
  static const double xxl = 24.0;
  static const double circle = 999.0;

  // Common radius values for specific components
  static const double radiusButton = sm;
  static const double radiusCard = lg;
  static const double radiusDialog = xl;
  static const double radiusSheet = xxl;

  // BorderRadius helpers
  static const BorderRadius allXS = BorderRadius.all(Radius.circular(xs));
  static const BorderRadius allSM = BorderRadius.all(Radius.circular(sm));
  static const BorderRadius allMD = BorderRadius.all(Radius.circular(md));
  static const BorderRadius allLG = BorderRadius.all(Radius.circular(lg));
  static const BorderRadius allXL = BorderRadius.all(Radius.circular(xl));
  static const BorderRadius allXXL = BorderRadius.all(Radius.circular(xxl));
  static const BorderRadius allCircle = BorderRadius.all(Radius.circular(circle));
}
