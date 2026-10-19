/// 电池诊断卡片（scene-to-gstore-parity Task 3）。
///
/// 目的：让用户**直接看到设备究竟上报了什么**，从而解释「看不到耗电信息」的
/// 原因（sysfs 被 SELinux 限制 / 采样器未运行 / 读数不完整 / 尚无落库样本）。
///
/// 卡片分两层：
/// * **常显**：标题 + 采样器摘要 + 「为何无数据」的简短原因提示（[batteryDiagnosticsHints]）；
/// * **展开**：读数（[BatteryReport] + `sources` / `basePath`）与采样器计数器
///   （[BatteryHistoryRecorder] 的 `isRecording` / `insertedCount` /
///   `skippedForScreenOffCount` / `lastSkipReason` / `lastSample`）。
///
/// ## 可注入 seam（务必保留）
/// 构造参数 `reading` / `sources` / `recorder` 均可注入：widget 测试无需触碰
/// FFI / 平台通道 / 真机。[recorder] 缺省为 App 级单例 [batteryHistoryRecorder]，
/// 卡片监听其 [ChangeNotifier] 通知以实时刷新。
///
/// ## 约定
/// 颜色 / 文字一律走 [Theme] 令牌，间距 / 圆角走设计令牌（AGENTS.md）；
/// 缺失字段展示 `—`；不硬编码颜色 / 字号。
library;

import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';

import 'package:gstore/core/design/design_tokens.dart';
import 'package:gstore/core/perf/battery_history_recorder.dart';
import 'package:gstore/core/rust/perf/PerfContract.dart';

import 'perf_common.dart';

/// 缺失字段占位（读数 / 计数器缺省一律展示）。
const String kBatteryDiagnosticsMissing = '—';

/// 由读数 + 采样器状态推导「为何无数据」的简短原因提示（纯函数）。
///
/// 返回**全部适用**的提示（可能为空 = 一切正常）；顺序即优先级：
/// 1. 采样器未运行 → `采样器未运行（main() 未启动？）`；
/// 2. 有电池但电流 / 电压缺失 → `电流/电压缺失（sysfs 被 SELinux 限制？…）`；
/// 3. 最近一拍因不完整被跳过 → `读数不完整，已跳过`；
/// 4. 采样中但零落库 → `尚无有效落库样本`。
List<String> batteryDiagnosticsHints({
  required BatteryReport? reading,
  required BatteryHistoryRecorder? recorder,
}) {
  final hints = <String>[];
  final recording = recorder?.isRecording ?? false;

  if (!recording) {
    hints.add('采样器未运行（main() 未启动？）');
  }

  // 仅在「确有电池但关键字段缺失」时提示 SELinux —— 无电池 / 未知不误报。
  if (reading != null &&
      reading.present &&
      (reading.currentMa == null || reading.voltageV == null)) {
    hints.add('电流/电压缺失（sysfs 被 SELinux 限制？尝试授权 Shizuku）');
  }

  if (recorder?.lastSkipReason == 'incomplete') {
    hints.add('读数不完整，已跳过');
  }

  if (recording && (recorder?.insertedCount ?? 0) == 0) {
    hints.add('尚无有效落库样本');
  }

  return hints;
}

/// 「电池诊断」紧凑可展开卡片（硬件 tab，紧随电池卡之后）。
class BatteryDiagnosticsCard extends StatefulWidget {
  const BatteryDiagnosticsCard({
    super.key,
    this.reading,
    this.sources = const <String>{},
    this.recorder,
  });

  /// 多源合并后的电池读数（生产：`PerfPageState.battery`）；`null` → 全 `—`。
  final BatteryReport? reading;

  /// 贡献过本读数的源（`sysfs` / `battery_manager` / `dumpsys`）；空集 → `—`。
  final Set<String> sources;

  /// 采样器；`null` → App 级单例 [batteryHistoryRecorder]。
  final BatteryHistoryRecorder? recorder;

  @override
  State<BatteryDiagnosticsCard> createState() => _BatteryDiagnosticsCardState();
}

class _BatteryDiagnosticsCardState extends State<BatteryDiagnosticsCard> {
  bool _expanded = false;

  BatteryHistoryRecorder get _recorder =>
      widget.recorder ?? batteryHistoryRecorder;

  @override
  void initState() {
    super.initState();
    _recorder.addListener(_onRecorderChanged);
  }

  @override
  void didUpdateWidget(covariant BatteryDiagnosticsCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.recorder != widget.recorder) {
      (oldWidget.recorder ?? batteryHistoryRecorder)
          .removeListener(_onRecorderChanged);
      _recorder.addListener(_onRecorderChanged);
    }
  }

  @override
  void dispose() {
    _recorder.removeListener(_onRecorderChanged);
    super.dispose();
  }

  void _onRecorderChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final recorder = _recorder;
    final hints = batteryDiagnosticsHints(
      reading: widget.reading,
      recorder: recorder,
    );
    final summary = '${recorder.isRecording ? '记录中' : '未运行'}'
        ' · 落库 ${recorder.insertedCount}';
    return Card(
      key: const Key('battery_diagnostics_card'),
      margin: AppSpacing.allLG,
      child: Padding(
        padding: AppSpacing.allLG,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  TablerIcons.battery,
                  size: AppTypography.iconMD,
                  color: scheme.primary,
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    '电池诊断',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: AppTypography.weightSemiBold,
                    ),
                  ),
                ),
                Text(
                  summary,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                IconButton(
                  key: const Key('battery_diagnostics_toggle'),
                  tooltip: _expanded ? '收起' : '展开',
                  onPressed: () => setState(() => _expanded = !_expanded),
                  icon: Icon(
                    _expanded
                        ? TablerIcons.chevron_up
                        : TablerIcons.chevron_down,
                    size: AppTypography.iconMD,
                  ),
                ),
              ],
            ),
            if (hints.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.xs),
              for (final hint in hints) _hintRow(context, theme, hint),
            ],
            if (_expanded) ...[
              const SizedBox(height: AppSpacing.md),
              Text('读数', style: theme.textTheme.titleSmall),
              const SizedBox(height: AppSpacing.xs),
              ..._readingRows(context),
              const SizedBox(height: AppSpacing.md),
              Text('采样器', style: theme.textTheme.titleSmall),
              const SizedBox(height: AppSpacing.xs),
              ..._recorderRows(context, recorder),
            ],
          ],
        ),
      ),
    );
  }

  Widget _hintRow(BuildContext context, ThemeData theme, String hint) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            TablerIcons.info_circle,
            size: AppTypography.iconSM,
            color: theme.colorScheme.error,
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              hint,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ==================== 读数 ====================

  List<Widget> _readingRows(BuildContext context) {
    final reading = widget.reading;
    final sources = widget.sources.isEmpty
        ? kBatteryDiagnosticsMissing
        : (widget.sources.toList()..sort()).join(', ');
    final present = reading == null
        ? kBatteryDiagnosticsMissing
        : (reading.present ? '已检测' : '未检测到');
    final capacity = reading?.capacityPercent == null
        ? kBatteryDiagnosticsMissing
        : '${reading!.capacityPercent!.toStringAsFixed(0)}%';
    final voltage = reading?.voltageV == null
        ? kBatteryDiagnosticsMissing
        : '${reading!.voltageV!.toStringAsFixed(2)} V';
    final current = reading?.currentMa == null
        ? kBatteryDiagnosticsMissing
        : '${reading!.currentMa!.toStringAsFixed(1)} mA';
    final temperature = reading?.temperatureC == null
        ? kBatteryDiagnosticsMissing
        : '${reading!.temperatureC!.toStringAsFixed(1)} °C';
    return <Widget>[
      perfKv(context, '检测', present),
      perfKv(context, '数据源', sources),
      perfKv(context, '基路径', reading?.basePath ?? kBatteryDiagnosticsMissing),
      perfKv(context, '电量', capacity),
      perfKv(context, '电压', voltage),
      perfKv(context, '电流', current),
      perfKv(context, '温度', temperature),
      perfKv(context, '状态', reading?.status ?? kBatteryDiagnosticsMissing),
      perfKv(context, '健康', reading?.health ?? kBatteryDiagnosticsMissing),
    ];
  }

  // ==================== 采样器 ====================

  List<Widget> _recorderRows(
    BuildContext context,
    BatteryHistoryRecorder recorder,
  ) {
    final sample = recorder.lastSample;
    final lastSampleText = sample == null
        ? kBatteryDiagnosticsMissing
        : '状态 ${sample.status}'
            ' · ${sample.screenOn ? '亮屏' : '熄屏'}'
            ' · 电流 ${_num(sample.currentMa, 1)}'
            ' · 电压 ${_num(sample.voltageV, 2)}'
            ' · 温度 ${_num(sample.temperatureC, 1)}'
            ' · 电量 ${_num(sample.capacityPercent, 0)}';
    return <Widget>[
      perfKv(context, '采样中', recorder.isRecording ? '是' : '否'),
      perfKv(context, '已落库', '${recorder.insertedCount}'),
      perfKv(context, '熄屏跳过', '${recorder.skippedForScreenOffCount}'),
      perfKv(
        context,
        '最近处置',
        recorder.lastSkipReason ?? kBatteryDiagnosticsMissing,
      ),
      perfKv(context, '最近样本', lastSampleText),
    ];
  }

  /// 数值 → 固定小数位；`null` → `—`。
  static String _num(double? value, int digits) =>
      value == null ? kBatteryDiagnosticsMissing : value.toStringAsFixed(digits);
}
