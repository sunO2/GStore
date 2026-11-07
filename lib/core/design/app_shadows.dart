import 'package:flutter/material.dart';

/// App shadow constants
/// Provides consistent elevation and shadow effects
class AppShadows {
  AppShadows._();

  static const double elevationNone = 0.0;
  static const double elevationSM = 1.0;
  static const double elevationMD = 4.0;
  static const double elevationLG = 8.0;

  /// 悬浮磨砂层（BackdropFilter）的高斯模糊半径。
  ///
  /// 成本与「像素数 × 核半径」成正比且每帧重算：`extendBody` 下滚动中的
  /// 列表作为背景，模糊不会命中缓存。取 8 是肉眼仍有磨砂感的上限，
  /// 相比 20 大约省 60% 的采样量。
  static const double backdropBlurSigma = 8.0;

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
