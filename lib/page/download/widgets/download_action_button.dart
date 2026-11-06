import 'package:flutter/material.dart';

/// 圆形图标操作按钮（暂停 / 继续 / 重试 / 取消）。
///
/// 比文字按钮更轻量：列表行里只占一个圆形图标位，语义由 [tooltip] 兜底；
/// 详情页可用更大的 [size] 作为主操作（媒体控制风格）。
class DownloadRoundActionButton extends StatelessWidget {
  const DownloadRoundActionButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.size = 40,
    this.color,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = onPressed != null;
    final tint = color ?? scheme.primary;

    return Tooltip(
      message: tooltip,
      child: Material(
        color: enabled
            ? tint.withValues(alpha: 0.12)
            : scheme.surfaceContainerHighest,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onPressed,
          child: SizedBox(
            width: size,
            height: size,
            child: Icon(
              icon,
              size: size * 0.5,
              color: enabled
                  ? tint
                  : scheme.onSurfaceVariant.withValues(alpha: 0.4),
            ),
          ),
        ),
      ),
    );
  }
}
