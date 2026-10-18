import 'package:flutter/material.dart';

import 'package:gstore/core/design/design_tokens.dart';
import 'package:gstore/core/rust/perf/PerfContract.dart';

/// 0–100 百分比条（[enabled] 为 false 时画空轨道）。
Widget perfPercentBar(
  BuildContext context,
  double percent, {
  bool enabled = true,
  Color? color,
}) {
  final scheme = Theme.of(context).colorScheme;
  return ClipRRect(
    borderRadius: AppRadius.allSM,
    child: LinearProgressIndicator(
      value: enabled ? (percent / 100).clamp(0.0, 1.0) : 0.0,
      color: color,
      backgroundColor: scheme.surfaceContainerHighest,
    ),
  );
}

// ==================== 通用小组件 ====================

Widget perfSectionHeader(
  BuildContext context,
  IconData icon,
  String title, {
  Widget? trailing,
}) {
  final theme = Theme.of(context);
  return Row(
    children: [
      Icon(icon, size: AppTypography.iconMD, color: theme.colorScheme.primary),
      const SizedBox(width: AppSpacing.sm),
      Expanded(
        child: Text(
          title,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: AppTypography.weightSemiBold,
          ),
        ),
      ),
      if (trailing != null) trailing,
    ],
  );
}

Widget perfMetric(
  BuildContext context,
  String label,
  String value, {
  String? sub,
  bool accent = false,
}) {
  final theme = Theme.of(context);
  final scheme = theme.colorScheme;
  return SizedBox(
    width: AppSpacing.massive * 2,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          value,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: AppTypography.weightSemiBold,
            color: accent ? scheme.error : null,
          ),
        ),
        if (sub != null)
          Text(
            sub,
            style: theme.textTheme.bodySmall?.copyWith(
              color: accent ? scheme.error : scheme.onSurfaceVariant,
            ),
          ),
      ],
    ),
  );
}

Widget perfKv(BuildContext context, String label, String value) {
  final theme = Theme.of(context);
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: AppSpacing.massive * 2,
          child: Text(
            label,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        Expanded(
          child: Text(value, style: theme.textTheme.bodyMedium),
        ),
      ],
    ),
  );
}

Widget perfEmptyCard(
  BuildContext context,
  IconData icon,
  String title,
  String message,
) {
  final theme = Theme.of(context);
  return Card(
    margin: AppSpacing.allLG,
    child: Padding(
      padding: AppSpacing.allLG,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          perfSectionHeader(context, icon, title),
          const SizedBox(height: AppSpacing.md),
          Text(
            message,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    ),
  );
}

Widget perfCoreChip(
  BuildContext context,
  int index,
  double usage,
  double? freqMhz,
) {
  final theme = Theme.of(context);
  final parts = <String>[
    '核$index',
    '${usage.toStringAsFixed(0)}%',
    if (freqMhz != null) '${freqMhz.toStringAsFixed(0)}MHz',
  ];
  return Container(
    padding: AppSpacing.horizontalSM_verticalXS,
    decoration: BoxDecoration(
      color: theme.colorScheme.surfaceContainerHighest,
      borderRadius: AppRadius.allSM,
    ),
    child: Text(parts.join('  '), style: theme.textTheme.bodySmall),
  );
}

Widget perfThermalRow(
  BuildContext context,
  ThermalZone zone,
  double? maxTemp,
) {
  final theme = Theme.of(context);
  final isMax = maxTemp != null && zone.tempC >= maxTemp;
  final label = zone.kind?.isNotEmpty == true ? zone.kind! : zone.zone;
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
    child: Row(
      children: [
        Expanded(
          child: Text(
            label,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: isMax ? theme.colorScheme.error : null,
              fontWeight:
                  isMax ? AppTypography.weightSemiBold : null,
            ),
          ),
        ),
        Text(
          '${zone.tempC.toStringAsFixed(1)} °C',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: isMax ? theme.colorScheme.error : null,
            fontWeight: isMax ? AppTypography.weightSemiBold : null,
          ),
        ),
      ],
    ),
  );
}

Widget perfProcessRow(BuildContext context, PerfProcessInfo process) {
  final theme = Theme.of(context);
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
    child: Row(
      children: [
        Expanded(
          child: Text(
            '${process.name} (${process.pid})',
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium,
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        Text(
          '${process.cpuPercent.toStringAsFixed(1)}%',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.primary,
            fontWeight: AppTypography.weightMedium,
          ),
        ),
        const SizedBox(width: AppSpacing.md),
        SizedBox(
          width: AppSpacing.huge * 2,
          child: Text(
            perfKbHuman(process.rssKb),
            textAlign: TextAlign.right,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    ),
  );
}

/// 单资源压力行：`some.avg10`（+ `avg60` / `full.avg10`）+ 0–100 条。
Widget perfPressureRow(
  BuildContext context,
  String label,
  PerfPressureSample? some,
  PerfPressureSample? full,
) {
  final theme = Theme.of(context);
  final scheme = theme.colorScheme;
  final detail = some == null
      ? '不可用'
      : 'some ${some.avg10.toStringAsFixed(2)}% · 60s '
          '${some.avg60.toStringAsFixed(2)}%'
          '${full == null ? '' : ' · full ${full.avg10.toStringAsFixed(2)}%'}';
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            SizedBox(
              width: AppSpacing.huge,
              child: Text(
                label,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: AppTypography.weightSemiBold,
                ),
              ),
            ),
            Expanded(
              child: Text(
                detail,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.xs),
        perfPercentBar(context, some?.avg10 ?? 0, enabled: some != null),
      ],
    ),
  );
}

// ==================== 单位格式化（纯函数） ====================

/// KiB → 人类可读字节串（内存 / 进程 RSS 兜底，模块未给 human 串时使用）。
String perfKbHuman(int kb) => perfBytesHuman(kb * 1024.0);

/// 字节 → 人类可读（B / KB / MB / GB / TB）。
String perfBytesHuman(double bytes) {
  if (bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes;
  var index = 0;
  while (value >= 1024 && index < units.length - 1) {
    value /= 1024;
    index++;
  }
  final digits = index == 0 || value >= 100 ? 0 : 1;
  return '${value.toStringAsFixed(digits)} ${units[index]}';
}

/// 字节/秒 → 速率串。
String perfRateHuman(double bytesPerSec) => '${perfBytesHuman(bytesPerSec)}/s';

/// µAh → mAh 串（`null` → 「不可用」）。
String perfUahMah(int? uah) =>
    uah == null ? '不可用' : '${(uah / 1000).toStringAsFixed(0)} mAh';

/// 数值格式化（1 位小数；`null` → 「—」）。
String perfNum(double? value) => value == null ? '—' : value.toStringAsFixed(1);
