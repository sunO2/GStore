import 'package:flutter/material.dart';

import 'package:gstore/core/core.dart';
import 'package:gstore/page/about/widgets/dot_matrix.dart';

/// GStore 品牌点阵 “GS”（11×7）：`#` 亮、`o` 强调点、`.` 灭。
///
/// 与 FluxDown 的 `BrandGlyph` 同构：右下角保留一枚强调点作为视觉焦点。
const List<String> kGStoreGlyph = <String>[
  '.####..####', // S 顶栏与中栏对齐（右起），避免首行比末行少一格
  '#.....#....', // G 与 S 之间必须留出一列，S 的左侧竖笔从下一列开始
  '#.....#....',
  '#..##..####',
  '#...#.....#',
  '#...#.....#',
  '.####.####o',
];

/// 「关于」页顶部品牌头：动画点阵 logo、应用名、描述、版本与内核版本。
///
/// 结构对齐 FluxDown：点阵 → GStore → 描述 → `v应用版本` + `GStore Core v内核版本`。
/// 版本用 `Future` 传入，读取期间显示 `…`，读取失败显示 `—`，绝不阻塞首帧。
class AboutBrandHeader extends StatelessWidget {
  const AboutBrandHeader({
    super.key,
    required this.appVersion,
    required this.coreVersion,
  });

  final Future<String?> appVersion;
  final Future<int?> coreVersion;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;

    return _FlowIn(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg,
          AppSpacing.xl,
          AppSpacing.lg,
          AppSpacing.lg,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const DotMatrix(
              rows: kGStoreGlyph,
              dot: 6,
              gap: 3,
              semanticLabel: 'GStore',
            ),
            const SizedBox(height: AppSpacing.lg + 2),
            Text(
              'GStore',
              textAlign: TextAlign.center,
              style: theme.textTheme.headlineSmall?.copyWith(
                color: scheme.onSurface,
                fontWeight: AppTypography.weightBold,
              ),
            ),
            const SizedBox(height: AppSpacing.xs + 2),
            Text(
              '开源 Android 应用商店',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            Wrap(
              alignment: WrapAlignment.center,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.xs,
              children: [
                FutureBuilder<String?>(
                  future: appVersion,
                  builder: (BuildContext context, AsyncSnapshot<String?> snap) {
                    return _VersionPill(text: _appVersionLabel(snap));
                  },
                ),
                FutureBuilder<int?>(
                  future: coreVersion,
                  builder: (BuildContext context, AsyncSnapshot<int?> snap) {
                    return _VersionPill(
                      text: _coreVersionLabel(snap),
                      accent: true,
                    );
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static String _appVersionLabel(AsyncSnapshot<String?> snap) {
    if (snap.connectionState == ConnectionState.waiting) return 'v…';
    final String? version = snap.data;
    if (version == null || version.isEmpty) return 'v—';
    return 'v$version';
  }

  static String _coreVersionLabel(AsyncSnapshot<int?> snap) {
    if (snap.connectionState == ConnectionState.waiting) {
      return 'GStore Core v…';
    }
    final int? version = snap.data;
    return version == null ? 'GStore Core —' : 'GStore Core v$version';
  }
}

class _VersionPill extends StatelessWidget {
  const _VersionPill({required this.text, this.accent = false});

  final String text;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm + 2,
        vertical: AppSpacing.xs - 1,
      ),
      decoration: BoxDecoration(
        color:
            accent ? scheme.primaryContainer : scheme.surfaceContainerHighest,
        borderRadius: AppRadius.allCircle,
        border: Border.all(
          color: accent
              ? scheme.primary.withValues(alpha: 0.35)
              : scheme.outlineVariant,
          width: 1,
        ),
      ),
      child: Text(
        text,
        style: TextStyle(
          // 内核版本文案更长，字号收小一档，避免比应用版本更抢眼。
          fontSize: accent ? AppTypography.sizeXXS : AppTypography.sizeXS,
          fontWeight: AppTypography.weightMedium,
          letterSpacing: 0.2,
          color: accent ? scheme.onPrimaryContainer : scheme.onSurfaceVariant,
          fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

/// 轻微上移 + 淡入的页面入场（Reduce motion 时直接呈现终态）。
class _FlowIn extends StatelessWidget {
  const _FlowIn({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final bool reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (reduceMotion) return child;

    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: const Duration(milliseconds: 420),
      curve: Curves.easeOutCubic,
      child: child,
      builder: (BuildContext context, double value, Widget? child) {
        return Opacity(
          opacity: value,
          child: Transform.translate(
            offset: Offset(0, (1 - value) * 8),
            child: child,
          ),
        );
      },
    );
  }
}
