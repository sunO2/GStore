import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:gstore/compent/banner_merge.dart';
import 'package:gstore/core/design/app_components.dart'
    show AppLoading, AppLoadingSize;
import 'package:gstore/core/design/app_radius.dart';
import 'package:gstore/core/design/app_spacing.dart';
import 'package:gstore/core/design/app_typography.dart';
import 'package:gstore/core/progress/task_progress.dart';
import 'package:gstore/core/rust/ModuleBootstrap.dart';

// 归并/去重/文案逻辑集中在 banner_merge.dart；此处再导出，保持既有
// `moduleInstallLabel` 等调用点的导入路径不变。
export 'package:gstore/compent/banner_merge.dart'
    show
        BannerCard,
        formatBytes,
        mergeBannerCards,
        moduleInstallLabel,
        moduleInstallLabels,
        modulePurposeLabel,
        modulePurposeLabels;

/// 原生模块安装状态聚合流 Provider。
///
/// 桥接 [ModuleBootstrap.states]（`Stream<List<ModuleBootstrapState>>`），
/// 供顶部安装进度横幅订阅。测试可经 `overrideWith` 注入受控状态流，
/// 从而**无需 FFI、无需网络**即可验证横幅的显示/隐藏。
final moduleBootstrapStatesProvider =
    StreamProvider<List<ModuleBootstrapState>>((ref) {
  return ModuleBootstrap.instance.states;
});

/// 通用任务中枢状态聚合流 Provider（如 F-Droid 仓库索引同步）。
///
/// 桥接 [TaskProgressHub.states]；真实 hub 默认没有任何条目，因此只覆盖
/// [moduleBootstrapStatesProvider] 的既有测试不受影响。需要注入任务来源时，
/// 在测试里覆盖本 Provider 即可。
final taskProgressStatesProvider =
    StreamProvider<List<TaskProgressState>>((ref) {
  return TaskProgressHub.instance.states;
});

/// 模块名 → Material 图标（与 [moduleInstallLabels] 对应）。
const Map<String, IconData> moduleInstallIcons = <String, IconData>{
  'qr': Icons.qr_code_2,
  'analyzer': Icons.analytics_outlined,
  'repo': Icons.source_outlined,
  'download': Icons.download_outlined,
  'llm': Icons.memory_outlined,
};

/// 返回模块的 Material 图标；未收录时回退为通用扩展图标。
IconData moduleInstallIcon(String module) =>
    moduleInstallIcons[module] ?? Icons.extension_outlined;

/// 卡片图标：`module:<name>` 键（含同键的仓库任务）沿用模块图标，
/// 使「模块安装 → 索引同步」视觉连续；其余任务使用通用同步图标。
IconData _iconForCard(BannerCard card) {
  const String modulePrefix = 'module:';
  if (card.cardKey.startsWith(modulePrefix)) {
    return moduleInstallIcon(card.cardKey.substring(modulePrefix.length));
  }
  return Icons.sync_outlined;
}

/// 卡片阴影高度：明显高于同页普通表面（0–2），与 `primaryContainer`
/// 底色一道把卡片从 `surface` 页面背景中托起（浅色下阴影为主，深色下
/// `primaryContainer` 与 `surface` 的色调差为主）。不再用描边换取浮起感——
/// 在已着色的 `primaryContainer` 表面再套粗描边会显得生硬。
const double _bannerCardElevation = 6;

/// 进度条轨道透明度：以 `onPrimaryContainer` 低透明度垫底，始终与
/// `primaryContainer` 底色成对（明/暗主题都可辨），无需任何硬编码颜色。
const double _progressTrackOpacity = 0.2;

/// 阶段动作句的强调透明度：以与底色成对的 `onPrimaryContainer` 呈现，
/// 但比标题略淡，成为「标题 > 阶段 > 详情」的第二强调级。刻意不用饱和
/// `primary`——它在 `primaryContainer` 上偏刺眼，正是本次要修的点。
const double _stageEmphasisOpacity = 0.85;

/// 详情行的强调透明度：三级中最低，退到「可读但安静」的背景位，
/// 避免三条文字同样大声。
const double _detailEmphasisOpacity = 0.65;

/// 顶部「模块安装 / 后台任务」卡片横幅。
///
/// 以 [Stack] 覆盖层方式挂载：第一个子节点是 [child]（被完整保留、全尺寸
/// 布局），叠加层是 `Positioned(top:0,left:0,right:0)` + `SafeArea(bottom:false)`，
/// 因此横幅渲染在状态栏之下且**不位移、不遮挡**应用内容。
///
/// 行为：
/// * 把 [moduleBootstrapStatesProvider] 与 [taskProgressStatesProvider] 两条来源
///   经 [mergeBannerCards] 归并为按键去重的卡片；无进行中条目时不渲染覆盖层；
/// * 进行中 → **每个条目一张紧凑卡片**（图标 + 中文标题 + 阶段 + 进度条 + 详情）；
/// * `ready`/`failed`/`absent` → 自动隐藏；
/// * 覆盖层包 [IgnorePointer] → 触摸事件穿透到应用，卡片刻意不放置任何可交互控件。
///
/// 颜色/文字一律取自 [Theme.of]（`colorScheme` / `textTheme`）与设计令牌
/// （`AppSpacing` / `AppRadius` / `AppTypography`），遵循 GStore 设计系统约束。
class ModuleInstallBanner extends ConsumerWidget {
  /// 构造横幅；[child] 为被叠加的应用内容。
  const ModuleInstallBanner({super.key, required this.child});

  /// 被覆盖层叠加的应用内容（保持原始布局尺寸）。
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final List<ModuleBootstrapState> modules =
        ref.watch(moduleBootstrapStatesProvider).valueOrNull ??
            const <ModuleBootstrapState>[];
    final List<TaskProgressState> tasks =
        ref.watch(taskProgressStatesProvider).valueOrNull ??
            const <TaskProgressState>[];
    final List<BannerCard> cards = mergeBannerCards(modules, tasks);

    return Stack(
      children: <Widget>[
        child,
        if (cards.isNotEmpty)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              bottom: false,
              child: IgnorePointer(
                child: _BannerOverlay(cards: cards),
              ),
            ),
          ),
      ],
    );
  }
}

/// 覆盖层：水平内缩、卡片之间留小间距，读起来是「浮起的一叠卡片」而非通栏条。
///
/// 紧凑性：每张卡片内容高度约 56–76px，且 [mergeBannerCards] 已按 `cardKey`
/// 去重（模块与同键任务合并、多来源聚合任务只占一张），因此少量卡片叠加不会
/// 吞掉视口；覆盖层本身限 `mainAxisSize.min`，不占满屏幕。
class _BannerOverlay extends StatelessWidget {
  const _BannerOverlay({required this.cards});

  final List<BannerCard> cards;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (var index = 0; index < cards.length; index++) ...<Widget>[
            if (index > 0) const SizedBox(height: AppSpacing.sm),
            _BannerCardView(card: cards[index]),
          ],
        ],
      ),
    );
  }
}

/// 单张卡片：高对比主题表面（`primaryContainer` 底 + 阴影，**无描边**）
/// + 图标 / 标题 / 阶段 / 进度条 / 详情。
///
/// **醒目性（为何不再与页面融为一体）**：页面背景取自 `surface` /
/// `surfaceContainer*`，而卡片改用 `primaryContainer`——两者是 Material 3
/// 中**成对设计、明暗主题都保持明显色差**的色调（浅色下浅紫 vs 近白，
/// 深色下暗紫 vs 近黑）。再叠加 `_bannerCardElevation` 阴影，即使色弱或
/// 强光下也能把卡片从页面背景中分离出来；**无需再套描边**（旧版 `primary`
/// 粗描边在已着色表面上显得生硬，已移除）。
///
/// **可读性（色调不能压过内容）**：前景全部取自与底色成对的
/// `onPrimaryContainer`，并按不透明度拉出「标题 > 阶段 > 详情」三级层次，
/// 而非三条同强度的实色或饱和 `primary`——醒目但不过分刺激。
class _BannerCardView extends StatelessWidget {
  const _BannerCardView({required this.card});

  final BannerCard card;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final TextTheme textTheme = theme.textTheme;

    return Material(
      color: scheme.primaryContainer,
      elevation: _bannerCardElevation,
      clipBehavior: Clip.antiAlias,
      // 仅保留圆角；`side` 保持默认 `BorderSide.none`，不再绘制任何描边。
      shape: const RoundedRectangleBorder(borderRadius: AppRadius.allLG),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.md,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            _BannerCardIcon(card: card),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          card.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: textTheme.titleSmall
                              ?.copyWith(color: scheme.onPrimaryContainer),
                        ),
                      ),
                      if (card.stage != null) ...<Widget>[
                        const SizedBox(width: AppSpacing.sm),
                        Text(
                          card.stage!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: textTheme.labelMedium?.copyWith(
                            color: scheme.onPrimaryContainer.withValues(
                              alpha: _stageEmphasisOpacity,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  ClipRRect(
                    borderRadius: AppRadius.allXS,
                    child: LinearProgressIndicator(
                      // progress 为 null → 不定量进度；有值 → 绑定具体比例。
                      value: card.progress,
                      minHeight: AppSpacing.xs,
                      color: scheme.primary,
                      backgroundColor: scheme.onPrimaryContainer
                          .withValues(alpha: _progressTrackOpacity),
                    ),
                  ),
                  if (card.detail != null) ...<Widget>[
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      card.detail!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.bodySmall?.copyWith(
                        color: scheme.onPrimaryContainer.withValues(
                          alpha: _detailEmphasisOpacity,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            const AppLoading(size: AppLoadingSize.small),
          ],
        ),
      ),
    );
  }
}

/// 卡片前导图标：实心 `primary` 方块内嵌 `onPrimary` 图标——在
/// `primaryContainer` 卡面上形成最实的对比锚点，第一眼就能看到。
class _BannerCardIcon extends StatelessWidget {
  const _BannerCardIcon({required this.card});

  final BannerCard card;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      width: AppSpacing.xxxl,
      height: AppSpacing.xxxl,
      decoration: BoxDecoration(
        color: scheme.primary,
        borderRadius: AppRadius.allMD,
      ),
      alignment: Alignment.center,
      child: Icon(
        _iconForCard(card),
        size: AppTypography.iconLG,
        color: scheme.onPrimary,
      ),
    );
  }
}
