import 'package:flutter/material.dart';

/// 主题边框助手：从当前主题 CardTheme.shape.side 读取边框宽度/透明度，
/// 保证手绘边框响应主题"边框风格"（borderStyle: 无边框/轻细/标准/粗犷）配置。
class AppBorders {
  AppBorders._();

  /// 主题侧边（含 borderWidth/borderOpacity 的 BorderSide），颜色可覆盖。
  ///
  /// 宽度/透明度取自 `Theme.of(context).cardTheme.shape.side`（由主题
  /// borderStyle 的 borderWidth/borderOpacity 构建）；cardTheme.shape 不是
  /// [RoundedRectangleBorder] 时回退到 outlineVariant + 1.0。
  /// 保留主题 side 的 style：无边框档（BorderStyle.none）时返回 none style，
  /// 调用方据此渲染真无边框（而非 BorderSide(width:0) 的 hairline）。
  static BorderSide sideOf(BuildContext context, {Color? color}) {
    final scheme = Theme.of(context).colorScheme;
    final shape = Theme.of(context).cardTheme.shape;
    final themeSide = shape is RoundedRectangleBorder ? shape.side : null;
    return BorderSide(
      color: color ?? (themeSide?.color ?? scheme.outlineVariant),
      width: themeSide?.width ?? 1.0,
      style: themeSide?.style ?? BorderStyle.solid,
    );
  }

  /// 四边统一边框（宽度/透明度随主题 borderStyle），颜色可覆盖。
  /// 无边框档（style none）时 Border.all 不绘制（真无边框）。
  static Border all(BuildContext context, {Color? color}) {
    final side = sideOf(context, color: color);
    return Border.all(color: side.color, width: side.width, style: side.style);
  }
}
