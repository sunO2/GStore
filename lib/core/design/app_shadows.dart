import 'package:flutter/material.dart';

/// App shadow constants
/// Provides consistent elevation and shadow effects
class AppShadows {
  AppShadows._();

  static const double elevationNone = 0.0;
  static const double elevationSM = 1.0;
  static const double elevationMD = 4.0;
  static const double elevationLG = 8.0;

  static const List<BoxShadow> shadowSM = [
    BoxShadow(
      color: Color.fromRGBO(0, 0, 0, 0.05),
      offset: Offset(0, 1),
      blurRadius: 2,
    ),
  ];

  static const List<BoxShadow> shadowMD = [
    BoxShadow(
      color: Color.fromRGBO(0, 0, 0, 0.1),
      offset: Offset(0, 2),
      blurRadius: 4,
    ),
  ];

  static const List<BoxShadow> shadowLG = [
    BoxShadow(
      color: Color.fromRGBO(0, 0, 0, 0.15),
      offset: Offset(0, 4),
      blurRadius: 8,
    ),
  ];
}
