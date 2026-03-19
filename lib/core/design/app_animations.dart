import 'package:flutter/material.dart';

/// App animation duration constants
/// Provides consistent animation timing across the application
class AppAnimations {
  AppAnimations._();

  static const Duration fast = Duration(milliseconds: 150);
  static const Duration normal = Duration(milliseconds: 300);
  static const Duration slow = Duration(milliseconds: 500);

  // Animation curves
  static const Curve curveDefault = Curves.easeInOut;
  static const Curve curveEaseIn = Curves.easeIn;
  static const Curve curveEaseOut = Curves.easeOut;
  static const Curve curveBounce = Curves.bounceInOut;

  // Common duration with curve combinations
  static const Cubic cubicDefault = Cubic(0.4, 0.0, 0.2, 1);
}
