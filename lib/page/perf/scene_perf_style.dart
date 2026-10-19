/// 性能监控页**本地**的 Scene 风格样式令牌（plan batch-2 前置）。
///
/// 本文件只服务「性能监控页」的 Scene 观感迁移：
/// * Scene 主强调色（`colors.xml:21 colorAccent` = `#BC8DE4`）作为**唯一**的
///   perf 本地颜色常量（AGENTS.md 禁止硬编码颜色的**唯一**豁免点：Scene 强调色
///   无对应主题角色，故收敛在此一处）；
/// * 密集扁平卡片的默认内边距 / 圆角 / 环形仪表尺寸；
/// * 分区标题样式助手；
/// * **集中色档→主题色映射**：把 [scene_thresholds.dart] 的档位
///   （[SceneLoadTier] / [SceneTempTier]）映射到主题语义角色 + Scene 强调色
///   （正常档 = 强调色，与 Scene `CpuChartView.kt:177` 的 `else accentColor` 一致）。
///
/// **不修改**全局 `ThemeData` / `AppColors` / `lib/core/theme/**`——所有非强调色
/// 一律取自 `Theme.of(context).colorScheme`。
library;

import 'package:flutter/material.dart';

import 'package:gstore/core/design/design_tokens.dart';
import 'package:gstore/core/perf/scene_thresholds.dart';

/// Scene 风格样式令牌（性能监控页本地；勿在其它页面复用）。
abstract final class ScenePerfStyle {
  ScenePerfStyle._();

  // ==================== 颜色 ====================

  /// Scene 主强调色（`colors.xml:21` `colorAccent` = `#BC8DE4`）。
  ///
  /// **唯一**允许的硬编码颜色：Scene 强调色在 Material 主题里没有语义角色，
  /// 因此收敛于此；环形仪表「正常档」与高亮态使用它。
  static const Color accent = Color(0xFFBC8DE4);

  // ==================== 尺寸 / 间距 ====================

  /// 密集卡片内边距（Scene 紧凑布局：12）。
  static const EdgeInsets cardPadding = EdgeInsets.all(AppSpacing.md);

  /// 更紧凑的行内边距（8）。
  static const EdgeInsets compactPadding = EdgeInsets.all(AppSpacing.sm);

  /// 卡片圆角（Scene 扁平圆角卡：16）。
  static const double cardRadius = AppRadius.lg;

  /// 卡片圆角对象。
  static const BorderRadius cardBorderRadius =
      BorderRadius.all(Radius.circular(cardRadius));

  /// 环形仪表默认边长。
  static const double ringSize = 96;

  /// 环形仪表默认线宽。
  static const double ringStrokeWidth = 10;

  /// 逐核网格单元宽度。
  static const double coreTileWidth = 72;

  // ==================== 分区标题 ====================

  /// 分区标题文字样式（Scene 扁平小标题：`titleSmall` + 半粗）。
  static TextStyle sectionTitle(BuildContext context) {
    final theme = Theme.of(context);
    return theme.textTheme.titleSmall!.copyWith(
      fontWeight: AppTypography.weightSemiBold,
    );
  }

  /// 分区标题行：图标 + 标题 + 可选 trailing（trailing 靠右）。
  static Widget sectionHeader(
    BuildContext context,
    IconData icon,
    String title, {
    Widget? trailing,
  }) {
    return Row(
      children: <Widget>[
        Icon(icon, size: AppTypography.iconMD, color: accent),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Text(title, style: sectionTitle(context)),
        ),
        if (trailing != null) trailing,
      ],
    );
  }

  // ==================== 色档 → 主题色映射 ====================

  /// 负载色档 → 颜色：`veryHigh` → [ColorScheme.error]；`high` →
  /// [ColorScheme.tertiary]；`normal` → [ScenePerfStyle.accent]。
  static Color loadTierColor(ColorScheme scheme, SceneLoadTier tier) =>
      switch (tier) {
        SceneLoadTier.veryHigh => scheme.error,
        SceneLoadTier.high => scheme.tertiary,
        SceneLoadTier.normal => accent,
      };

  /// 温度色档 → 颜色：`veryHigh` / `high` → [ColorScheme.error]；`mid` →
  /// [ColorScheme.tertiary]；`normal` → [ScenePerfStyle.accent]。
  static Color tempTierColor(ColorScheme scheme, SceneTempTier tier) =>
      switch (tier) {
        SceneTempTier.veryHigh => scheme.error,
        SceneTempTier.high => scheme.error,
        SceneTempTier.mid => scheme.tertiary,
        SceneTempTier.normal => accent,
      };

  /// CPU 负载（%）→ 颜色（复用集中阈值 [sceneCpuLoadTier]）。
  static Color cpuColor(ColorScheme scheme, double percent) =>
      loadTierColor(scheme, sceneCpuLoadTier(percent));

  /// RAM 使用率（%）→ 颜色（复用集中阈值 [sceneRamLoadTier]）。
  static Color ramColor(ColorScheme scheme, double percent) =>
      loadTierColor(scheme, sceneRamLoadTier(percent));

  /// 温度（°C）→ 颜色（复用集中阈值 [sceneTempTier]）。
  static Color temperatureColor(ColorScheme scheme, double tempC) =>
      tempTierColor(scheme, sceneTempTier(tempC));

  /// 无数据时的降级轨道 / 文字色（取 `onSurfaceVariant`）。
  static Color unavailableColor(ColorScheme scheme) => scheme.onSurfaceVariant;
}
