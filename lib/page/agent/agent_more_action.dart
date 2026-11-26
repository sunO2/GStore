import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:gstore/core/agent/agent_service.dart';
import 'package:gstore/core/design/app_colors.dart';
import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/design/app_spacing.dart';
import 'package:gstore/core/design/app_typography.dart';
import 'package:gstore/core/agent/agent_session_tokens.dart';

/// 导航栏右上角「更多」：竖三点 + 会话上下文进度环。
///
/// 环的比例 = 当前会话上下文估算 / 1M（[kAgentSessionContextLimitTokens]），
/// 菜单里同时展示本会话累计 input/output token 与压缩次数。
class AgentMoreAction extends StatelessWidget {
  const AgentMoreAction({
    super.key,
    required this.service,
    required this.onNewSession,
    required this.onShowSessions,
    required this.onOpenSettings,
  });

  final AgentService? service;
  final VoidCallback onNewSession;
  final VoidCallback onShowSessions;
  final VoidCallback onOpenSettings;

  static const Key buttonKey = Key('agent-more-button');
  static const Key ringKey = Key('agent-token-ring');

  @override
  Widget build(BuildContext context) {
    final notifier = service?.sessionTokens;
    final child = notifier == null
        ? _buildButton(context, AgentSessionTokenStats.empty)
        : ValueListenableBuilder<AgentSessionTokenStats>(
            valueListenable: notifier,
            builder: (context, stats, _) => _buildButton(context, stats),
          );
    return Padding(
      padding: const EdgeInsets.only(right: AppSpacing.md),
      child: child,
    );
  }

  Widget _buildButton(BuildContext context, AgentSessionTokenStats stats) {
    final scheme = Theme.of(context).colorScheme;
    final ratio = stats.ratio();
    final percent = _formatPercent(ratio);
    final usedColor = _usageColor(scheme, ratio);
    return PopupMenuButton<_MoreAction>(
      key: buttonKey,
      tooltip: '更多 · 上下文 $percent',
      position: PopupMenuPosition.under,
      // 点击水波纹/高亮限制在圆形内，避免方形阴影感
      borderRadius: BorderRadius.circular(23),
      splashRadius: 23,
      // 收窄弹出菜单
      constraints: const BoxConstraints(minWidth: 148, maxWidth: 164),
      onSelected: (value) async {
        switch (value) {
          case _MoreAction.newSession:
            onNewSession();
          case _MoreAction.sessions:
            onShowSessions();
          case _MoreAction.settings:
            onOpenSettings();
          case _MoreAction.compact:
            final compacted = await service?.compactSessionNow() ?? false;
            if (!context.mounted) return;
            AppDialogs.showSuccess(
              compacted ? '已压缩上下文' : '当前会话无需压缩',
            );
        }
      },
      itemBuilder: (context) {
        final current = service?.sessionTokens.value ?? stats;
        return [
          _menuItem(context, _MoreAction.newSession, TablerIcons.message_plus,
              '新建会话'),
          _menuItem(context, _MoreAction.sessions, TablerIcons.history, '会话列表'),
          _menuItem(context, _MoreAction.settings, TablerIcons.settings, '设置'),
          const PopupMenuDivider(),
          PopupMenuItem<_MoreAction>(
            enabled: false,
            height: 80,
            child: _TokenStatsBlock(stats: current),
          ),
          PopupMenuItem<_MoreAction>(
            value: _MoreAction.compact,
            enabled: service != null && !service!.isBusy,
            height: 56,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '压缩上下文',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                ),
                const SizedBox(height: AppSpacing.xs),
                _CompressCountPill(count: current.compactCount),
              ],
            ),
          ),
        ];
      },
      child: AgentSessionTokenRing(
        key: ringKey,
        progress: ratio,
        usedColor: usedColor,
        remainingColor: scheme.outlineVariant,
      ),
    );
  }

  PopupMenuItem<_MoreAction> _menuItem(
    BuildContext context,
    _MoreAction value,
    IconData icon,
    String label, {
    bool enabled = true,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return PopupMenuItem<_MoreAction>(
      value: value,
      enabled: enabled,
      child: Row(
        children: [
          Icon(icon,
              size: AppTypography.iconMD, color: scheme.onSurfaceVariant),
          const SizedBox(width: AppSpacing.md),
          Text(label, style: Theme.of(context).textTheme.bodyMedium),
        ],
      ),
    );
  }
}

enum _MoreAction { newSession, sessions, settings, compact }

/// 已用 / 剩余两段圆弧 + 竖三点。
///
/// 两段圆弧各自使用圆角端点，并在两处交界留出小空隙；比例按“可用角度”
/// 分配，避免 0%/100% 时出现半截圆点。
class AgentSessionTokenRing extends StatelessWidget {
  const AgentSessionTokenRing({
    super.key,
    required this.progress,
    required this.usedColor,
    required this.remainingColor,
  });

  /// 0~1
  final double progress;
  final Color usedColor;
  final Color remainingColor;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 46,
      height: 46,
      child: Center(
        child: SizedBox(
          width: 38,
          height: 38,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Positioned.fill(
                child: CustomPaint(
                  painter: _SegmentedRingPainter(
                    progress: progress,
                    usedColor: usedColor,
                    remainingColor: remainingColor,
                    strokeWidth: 3.4,
                  ),
                ),
              ),
              Icon(
                TablerIcons.dots_vertical,
                size: AppTypography.iconXL,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 两段圆角圆弧：已用 + 剩余。
class _SegmentedRingPainter extends CustomPainter {
  _SegmentedRingPainter({
    required this.progress,
    required this.usedColor,
    required this.remainingColor,
    required this.strokeWidth,
  });

  final double progress;
  final Color usedColor;
  final Color remainingColor;
  final double strokeWidth;

  /// 两段之间的空隙（弧度，约 23°）
  static const double _gap = 0.40;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = (size.shortestSide - strokeWidth) / 2;
    if (radius <= 0) return;

    final ratio = progress.clamp(0.0, 1.0).toDouble();
    // 预留两处空隙，剩余角度按比例分给两段
    const available = math.pi * 2 - _gap * 2;
    final usedSweep = available * ratio;
    final remainingSweep = available - usedSweep;
    const start = -math.pi / 2 + _gap / 2;

    final rect = Rect.fromCircle(center: center, radius: radius);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;

    if (usedSweep > 0.001) {
      paint.color = usedColor;
      canvas.drawArc(rect, start, usedSweep, false, paint);
    }
    if (remainingSweep > 0.001) {
      paint.color = remainingColor;
      canvas.drawArc(
        rect,
        start + usedSweep + _gap,
        remainingSweep,
        false,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _SegmentedRingPainter oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.usedColor != usedColor ||
      oldDelegate.remainingColor != remainingColor ||
      oldDelegate.strokeWidth != strokeWidth;
}

class _TokenStatsBlock extends StatelessWidget {
  const _TokenStatsBlock({required this.stats});

  final AgentSessionTokenStats stats;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final ratio = stats.ratio();
    final progress = ratio.clamp(0.0, 1.0).toDouble();
    // 已使用胶囊：主题色由浅到深（不跟随 80% 警告）
    final usageBackground = Color.lerp(
      scheme.primary.withValues(alpha: 0.12),
      scheme.primary,
      progress,
    )!;
    final usageTextColor = Color.lerp(
      scheme.onSurface,
      scheme.onPrimary,
      progress,
    )!;

    return SizedBox(
      width: 120,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '本会话 Tokens',
            style: theme.textTheme.labelMedium?.copyWith(
              color: scheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: AppSpacing.xs + 2),
          // 输入/输出：箭头 + 数字，各自一个胶囊，保持同一行
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _arrowPill(
                  context,
                  TablerIcons.arrow_up,
                  _formatTokens(stats.inputTokens),
                ),
                const SizedBox(width: 6),
                _arrowPill(
                  context,
                  TablerIcons.arrow_down,
                  _formatTokens(stats.outputTokens),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.xs + 2),
          // 已用 / 上限分别用胶囊包裹，中间用 / 表示比例
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _TokenPill(
                  text: _formatTokens(stats.contextTokens),
                  background: usageBackground,
                  foreground: usageTextColor,
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.xs,
                  ),
                  child: Text(
                    '/',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                _TokenPill(
                  text: _formatTokens(kAgentSessionContextLimitTokens),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _arrowPill(BuildContext context, IconData icon, String text) {
    final scheme = Theme.of(context).colorScheme;
    return _TokenPill(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon,
              size: AppTypography.iconXS, color: scheme.onSurfaceVariant),
          const SizedBox(width: 2),
          Text(text),
        ],
      ),
    );
  }
}

/// 压缩次数胶囊：[图标 + N次]。
class _CompressCountPill extends StatelessWidget {
  const _CompressCountPill({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return _TokenPill(
      // 压缩次数用主题容器色，确保在菜单里也有明显背景
      background: scheme.secondaryContainer,
      foreground: scheme.onSecondaryContainer,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            TablerIcons.refresh,
            size: AppTypography.iconXS,
            color: scheme.onSecondaryContainer,
          ),
          const SizedBox(width: 2),
          Text('$count次'),
        ],
      ),
    );
  }
}

/// 统计区的小胶囊。
class _TokenPill extends StatelessWidget {
  const _TokenPill({
    this.child,
    this.text,
    this.background,
    this.foreground,
  }) : assert(child != null || text != null);

  final Widget? child;
  final String? text;
  final Color? background;
  final Color? foreground;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final fg = foreground ?? scheme.onSurfaceVariant;
    final content = child ??
        Text(
          text!,
          style: theme.textTheme.labelSmall?.copyWith(
            color: fg,
            fontWeight: FontWeight.w600,
          ),
        );
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: 3,
      ),
      decoration: BoxDecoration(
        // 用 onSurface 半透明填充，保证在菜单底色上也能明显看出胶囊
        color: background ?? scheme.onSurface.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.55),
        ),
      ),
      child: DefaultTextStyle.merge(
        style: theme.textTheme.labelSmall?.copyWith(
          color: fg,
          fontWeight: FontWeight.w600,
        ),
        child: content,
      ),
    );
  }
}

/// 超过该比例进入黄色警告色
const double _warningThreshold = 0.8;

/// 已用进度颜色：未超阈值时灰白偏白，≥80% 警告黄。
Color _usageColor(ColorScheme scheme, double ratio) {
  if (ratio >= _warningThreshold) return AppColors.warning;
  return scheme.onSurface.withValues(alpha: 0.9);
}

String _formatTokens(int value) {
  if (value >= 1000000) {
    return '${(value / 1000000).toStringAsFixed(1)}M';
  }
  if (value >= 1000) {
    return '${(value / 1000).toStringAsFixed(1)}k';
  }
  return '$value';
}

String _formatPercent(double ratio) {
  final percent = ratio * 100;
  if (percent >= 100) return '100%+';
  if (percent >= 10) return '${percent.toStringAsFixed(0)}%';
  return '${percent.toStringAsFixed(1)}%';
}
