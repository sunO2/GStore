import 'app_radius.dart';
import 'app_spacing.dart';

/// 底部悬浮胶囊的统一尺寸（首页悬浮导航胶囊 / AI 助手悬浮输入胶囊共用）。
///
/// 切到 AI 助手 tab 时，导航胶囊下滑滑出、输入胶囊从同一位置出现；两者只有
/// 保持**等高、同等外边距、同等圆角**，切换时才像"同一个胶囊"在变形，
/// 而不是两个高度/位置不同的组件在交换。
class AppBottomCapsule {
  AppBottomCapsule._();

  /// 胶囊高度（首页导航胶囊压缩后的高度）。
  static const double height = 64;

  /// 左右外边距（胶囊与屏幕边缘的距离）。
  static const double horizontalMargin = AppSpacing.lg;

  /// 底部外边距（在 SafeArea 安全区之上再留出的距离）。
  static const double bottomMargin = AppSpacing.md;

  /// 大圆角：高度 64 时近似全圆。
  static const double radius = AppRadius.xxl + AppRadius.sm;

  /// 胶囊自身占用的垂直空间（高度 + 底部外边距），用于列表避让计算。
  static const double occupiedHeight = height + bottomMargin;
}
