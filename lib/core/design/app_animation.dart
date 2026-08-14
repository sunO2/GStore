import 'package:flutter/animation.dart';

/// App animation timing constants
/// Provides consistent animation durations/curves across the application.
class AppAnimation {
  AppAnimation._();

  /// 快速（状态微交互）
  static const Duration fast = Duration(milliseconds: 200);

  /// 中速（区块展开/折叠）
  static const Duration medium = Duration(milliseconds: 320);

  /// 慢速（页面级/loading 过渡）
  static const Duration slow = Duration(milliseconds: 450);

  /// 基础曲线（展开/出现）
  static const Curve curve = Curves.easeOutCubic;

  /// 弹性曲线（展开轻过冲）
  static const Curve spring = Curves.easeOutBack;

  /// 交错间隔（列表/区块依次出现）
  static const Duration stagger = Duration(milliseconds: 45);
}
