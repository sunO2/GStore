/// 耗电统计页（plan todo 20 / Scene `AdapterBatteryStats` 等价）。
///
/// 数据源 = todo 18 的 [BatteryHistoryStore]（**复用，不新建 store/引擎**）：
/// * **按时间**：按 `session` 分组展示每个录制会话的时长 / 估算 mAh / 温度
///   （平均·最低·最高）/ 样本数；
/// * **按应用**：选定会话内按 `(package, mode)` 分组聚合（逐字复用 todo-18 的
///   Scene SQL 口径，见 `battery_history.dart` 的 [aggregateAppPower]）——
///   平均电流 (mA)、平均功率、平均·最低·最高温度、样本数。
///
/// ## 口径与单位（task-33 取证）
/// * 温度 ℃、电流 mA、电压 volt、电量 %；
/// * 有效功耗样本 = `screen_on = 1 且 status in (3, 4)`（放电 / 未充电）；
/// * **按时间的「估算 mAh」是本页派生的展示量**（非 Scene 表内字段）：对有效
///   功耗样本按时间做**梯形积分** ∫ current(mA) dt(h)，仅用于「一段时间的放电量」
///   直观展示；功率单位本身在 task-33 标 `unverified`，故该值同为**估算**。
///
/// ## 约定
/// 弹层一律经统一骨架（[AppDialogs] / [AppSheet]）；loading 用 [AppLoading]；
/// 颜色 / 文字走 [Theme] 令牌，间距 / 圆角走设计令牌（AGENTS.md）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';

import 'package:gstore/core/core.dart';
import 'package:gstore/core/perf/battery_history.dart';
import 'package:gstore/core/perf/battery_history_store.dart';

import 'perf_common.dart';

/// 聚合视角：按时间（会话）/ 按应用。
enum _StatsMode { byTime, byApp }

/// 耗电统计页面。
///
/// [store] 为可选注入：生产传 `null` → 用 [SharedPrefsBatteryHistoryStore]；
/// 测试注入 [InMemoryBatteryHistoryStore] 避开 `shared_preferences` 平台通道。
/// 读取失败一律降级为空列表（store 自身静默），页面不抛出。
class BatteryStatsPage extends StatefulWidget {
  const BatteryStatsPage({super.key, this.store});

  /// 电池历史存储；`null` 时用生产 [SharedPrefsBatteryHistoryStore]。
  final BatteryHistoryStore? store;

  @override
  State<BatteryStatsPage> createState() => _BatteryStatsPageState();
}

class _BatteryStatsPageState extends State<BatteryStatsPage> {
  late final BatteryHistoryStore _store;

  bool _loading = true;
  List<BatteryHistoryRecord> _records = const <BatteryHistoryRecord>[];
  _StatsMode _mode = _StatsMode.byTime;

  /// 按应用视角当前选中的会话（`null` = 取最新会话）。
  int? _selectedSession;

  @override
  void initState() {
    super.initState();
    _store = widget.store ?? const SharedPrefsBatteryHistoryStore();
    _reload();
  }

  Future<void> _reload() async {
    if (mounted) setState(() => _loading = true);
    final records = await _store.load();
    if (!mounted) return;
    setState(() {
      _records = records;
      _loading = false;
      // 选中会话失效（清空 / 裁剪）→ 回退到最新会话。
      final sessions = _sessions;
      if (sessions.isEmpty) {
        _selectedSession = null;
      } else if (_selectedSession == null ||
          !sessions.any((s) => s.session == _selectedSession)) {
        _selectedSession = sessions.first.session;
      }
    });
  }

  Future<void> _clearAll() async {
    final ok = await AppDialogs.showConfirmSheet(
      title: '清空电池记录？',
      message: '将删除全部电池 / 功耗历史记录，此操作无法撤销。',
      confirmText: '清空',
      isDangerous: true,
      icon: const Icon(TablerIcons.trash),
    );
    if (ok != true || !mounted) return;
    await _store.clear();
    if (!mounted) return;
    AppDialogs.showInfo('已清空电池记录');
    await _reload();
  }

  /// 会话摘要（最新在前）。
  List<_SessionSummary> get _sessions => _summarizeSessions(_records);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasData = _records.isNotEmpty;
    return Scaffold(
      appBar: AppBar(
        title: const Text('耗电统计'),
        actions: [
          IconButton(
            key: const Key('battery_stats_refresh'),
            tooltip: '刷新',
            onPressed: _loading ? null : _reload,
            icon: const Icon(TablerIcons.refresh, size: AppTypography.iconMD),
          ),
          IconButton(
            key: const Key('battery_stats_clear'),
            tooltip: '清空记录',
            onPressed: (!_loading && hasData) ? _clearAll : null,
            icon: const Icon(TablerIcons.trash, size: AppTypography.iconMD),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: AppLoading())
          : !hasData
              ? _emptyState(context, theme)
              : _content(context, theme),
    );
  }

  // ==================== 空状态 ====================

  Widget _emptyState(BuildContext context, ThemeData theme) {
    final scheme = theme.colorScheme;
    return Center(
      child: Padding(
        padding: AppSpacing.allXXL,
        child: Column(
          key: const Key('battery_stats_empty'),
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              TablerIcons.battery,
              size: AppTypography.iconGiant,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(height: AppSpacing.md),
            Text(
              '暂无电池记录',
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              '开启电池采样后，此处按时间 / 应用汇总放电量与温度。',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            FilledButton.tonalIcon(
              key: const Key('battery_stats_empty_refresh'),
              onPressed: _reload,
              icon: const Icon(TablerIcons.refresh, size: AppTypography.iconSM),
              label: const Text('刷新'),
            ),
          ],
        ),
      ),
    );
  }

  // ==================== 主内容 ====================

  Widget _content(BuildContext context, ThemeData theme) {
    return Column(
      children: [
        Padding(
          padding: AppSpacing.horizontalLG_verticalMD,
          child: AppSegmentedButton<_StatsMode>(
            key: const Key('battery_stats_mode'),
            value: _mode,
            segments: const [
              AppSegment<_StatsMode>(
                value: _StatsMode.byTime,
                label: '按时间',
                icon: TablerIcons.clock,
                key: Key('battery_stats_mode_time'),
              ),
              AppSegment<_StatsMode>(
                value: _StatsMode.byApp,
                label: '按应用',
                icon: TablerIcons.apps,
                key: Key('battery_stats_mode_app'),
              ),
            ],
            onChanged: (value) => setState(() => _mode = value),
          ),
        ),
        Expanded(
          child: _mode == _StatsMode.byTime
              ? _byTimeView(context, theme)
              : _byAppView(context, theme),
        ),
      ],
    );
  }

  // ==================== 按时间 ====================

  Widget _byTimeView(BuildContext context, ThemeData theme) {
    final sessions = _sessions;
    return ListView(
      padding: AppSpacing.horizontalLG_bottomLG,
      children: [
        for (final summary in sessions) ...[
          _sessionCard(context, theme, summary),
          const SizedBox(height: AppSpacing.md),
        ],
        const SizedBox(height: AppSpacing.xxl),
      ],
    );
  }

  Widget _sessionCard(
    BuildContext context,
    ThemeData theme,
    _SessionSummary summary,
  ) {
    final scheme = theme.colorScheme;
    final durationMs = summary.endMs - summary.startMs;
    return Card(
      key: Key('battery_stats_session_card_${summary.session}'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: AppSpacing.allLG,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  TablerIcons.bolt,
                  size: AppTypography.iconMD,
                  color: scheme.primary,
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    '会话 ${summary.session}',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: AppTypography.weightSemiBold,
                    ),
                  ),
                ),
                Text(
                  '${summary.sampleCount} 样本',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              '${_formatClockTime(summary.startMs)} → '
              '${_formatClockTime(summary.endMs)}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            Wrap(
              spacing: AppSpacing.xl,
              runSpacing: AppSpacing.md,
              children: [
                perfMetric(
                  context,
                  '时长',
                  _formatDurationMs(durationMs),
                ),
                perfMetric(
                  context,
                  '估算放电量',
                  '${summary.milliampHours.toStringAsFixed(0)} mAh',
                  sub: '梯形积分估算',
                ),
                perfMetric(
                  context,
                  '平均温度',
                  _formatTemp(summary.avgTemperature),
                ),
                perfMetric(
                  context,
                  '温度范围',
                  summary.minTemperature == null || summary.maxTemperature == null
                      ? '—'
                      : '${summary.minTemperature!.toStringAsFixed(1)} ~ '
                          '${summary.maxTemperature!.toStringAsFixed(1)} °C',
                ),
              ],
            ),
            if (summary.powerSampleCount == 0) ...[
              const SizedBox(height: AppSpacing.sm),
              _noPowerSampleNote(
                context,
                theme,
                key: Key('battery_stats_no_power_note_${summary.session}'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ==================== 按应用 ====================

  Widget _byAppView(BuildContext context, ThemeData theme) {
    final sessions = _sessions;
    if (sessions.isEmpty) {
      return _byAppEmpty(context, theme, '暂无可选会话');
    }
    final selected = sessions.firstWhere(
      (s) => s.session == _selectedSession,
      orElse: () => sessions.first,
    );
    final stats = aggregateAppPower(_records, session: selected.session);
    return Column(
      children: [
        Padding(
          padding: AppSpacing.horizontalLG_bottomMD,
          child: DropdownButtonFormField<int>(
            key: const Key('battery_stats_session_picker'),
            initialValue: selected.session,
            isDense: true,
            decoration: const InputDecoration(
              labelText: '会话',
              isDense: true,
              border: OutlineInputBorder(),
            ),
            items: [
              for (final session in sessions)
                DropdownMenuItem<int>(
                  value: session.session,
                  child: Text(
                    '会话 ${session.session} · '
                        '${_formatClockTime(session.startMs)}',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: (value) {
              if (value != null) setState(() => _selectedSession = value);
            },
          ),
        ),
        Expanded(
          child: stats.isEmpty
              ? (selected.powerSampleCount == 0
                  // 会话有记录，但没有一条有效功耗样本 → 显式说明「为何为 0」。
                  ? _noPowerSampleNote(
                      context,
                      theme,
                      key: const Key('battery_stats_no_power_note'),
                    )
                  : _byAppEmpty(
                      context,
                      theme,
                      '该会话暂无逐应用功耗样本\n'
                          '（需屏幕点亮且处于放电 / 未充电状态）',
                    ))
              : ListView(
                  padding: AppSpacing.horizontalLG_bottomLG,
                  children: [
                    for (final stat in stats) ...[
                      _appStatCard(context, theme, stat),
                      const SizedBox(height: AppSpacing.md),
                    ],
                    const SizedBox(height: AppSpacing.xxl),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _byAppEmpty(BuildContext context, ThemeData theme, String message) {
    final scheme = theme.colorScheme;
    return Center(
      child: Padding(
        padding: AppSpacing.allXXL,
        child: Text(
          message,
          key: const Key('battery_stats_app_empty'),
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }

  /// 「仅有充电 / 无效样本」提示（非空 store，但零 [BatteryHistoryRecord.isPowerSample]）。
  ///
  /// 与「空 store」区分：真正空的 store 仍走 [build] 的空状态。
  Widget _noPowerSampleNote(
    BuildContext context,
    ThemeData theme, {
    Key? key,
  }) {
    final scheme = theme.colorScheme;
    return Padding(
      key: key,
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            TablerIcons.info_circle,
            size: AppTypography.iconSM,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              '该会话仅有充电/无效样本，未计入功耗统计',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _appStatCard(
    BuildContext context,
    ThemeData theme,
    BatteryAppPowerStat stat,
  ) {
    final scheme = theme.colorScheme;
    final mode = stat.mode.isEmpty ? '未标注' : stat.mode;
    return Card(
      key: Key('battery_stats_app_${stat.package}'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: AppSpacing.allLG,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  TablerIcons.apps,
                  size: AppTypography.iconMD,
                  color: scheme.primary,
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    stat.package.isEmpty ? '未知应用' : stat.package,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: AppTypography.weightSemiBold,
                    ),
                  ),
                ),
                Text(
                  mode,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            Wrap(
              spacing: AppSpacing.xl,
              runSpacing: AppSpacing.md,
              children: [
                perfMetric(
                  context,
                  '平均电流',
                  '${stat.current.toStringAsFixed(1)} mA',
                ),
                perfMetric(
                  context,
                  '平均功率',
                  stat.power.toStringAsFixed(0),
                  sub: '单位 unverified',
                ),
                perfMetric(
                  context,
                  '平均温度',
                  _formatTemp(stat.avgTemperature),
                ),
                perfMetric(
                  context,
                  '温度范围',
                  '${stat.minTemperature.toStringAsFixed(1)} ~ '
                      '${stat.maxTemperature.toStringAsFixed(1)} °C',
                ),
                perfMetric(context, '样本数', '${stat.count}'),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ==================== 会话聚合（纯函数，展示用） ====================

/// 单个会话的按时间摘要。
class _SessionSummary {
  const _SessionSummary({
    required this.session,
    required this.startMs,
    required this.endMs,
    required this.sampleCount,
    required this.powerSampleCount,
    required this.avgTemperature,
    required this.minTemperature,
    required this.maxTemperature,
    required this.milliampHours,
  });

  final int session;
  final int startMs;
  final int endMs;
  final int sampleCount;

  /// 有效功耗样本数（[BatteryHistoryRecord.isPowerSample]）；用于「仅有充电 /
  /// 无效样本」提示（[sampleCount] > 0 但本值为 0）。
  final int powerSampleCount;

  /// 平均温度（℃）；无有效温度样本 → `null`。
  final double? avgTemperature;

  /// 最低温度（℃）；无有效温度样本 → `null`。
  final double? minTemperature;

  /// 最高温度（℃）；无有效温度样本 → `null`。
  final double? maxTemperature;

  /// 估算放电量（mAh，梯形积分；见 [_sessionMilliampHours]）。
  final double milliampHours;
}

/// 按 `session` 分组并生成摘要（按最近时间降序）。
List<_SessionSummary> _summarizeSessions(List<BatteryHistoryRecord> records) {
  final byId = <int, List<BatteryHistoryRecord>>{};
  for (final record in records) {
    byId.putIfAbsent(record.session, () => <BatteryHistoryRecord>[]).add(record);
  }
  final summaries = <_SessionSummary>[
    for (final entry in byId.entries) _buildSummary(entry.key, entry.value),
  ];
  summaries.sort((a, b) {
    final byEnd = b.endMs.compareTo(a.endMs); // 新 → 旧
    if (byEnd != 0) return byEnd;
    return b.session.compareTo(a.session);
  });
  return summaries;
}

_SessionSummary _buildSummary(
  int session,
  List<BatteryHistoryRecord> group,
) {
  final sorted = List<BatteryHistoryRecord>.of(group)
    ..sort((a, b) => _timeMsOf(a).compareTo(_timeMsOf(b)));
  final startMs = _timeMsOf(sorted.first);
  final endMs = _timeMsOf(sorted.last);

  var minTemp = double.infinity;
  var maxTemp = double.negativeInfinity;
  var sumTemp = 0.0;
  var tempCount = 0;
  for (final record in sorted) {
    // Scene 默认 temperature = -1 表示未知，排除出温度统计。
    if (record.temperature < 0) continue;
    sumTemp += record.temperature;
    if (record.temperature < minTemp) minTemp = record.temperature;
    if (record.temperature > maxTemp) maxTemp = record.temperature;
    tempCount++;
  }

  return _SessionSummary(
    session: session,
    startMs: startMs,
    endMs: endMs,
    sampleCount: sorted.length,
    powerSampleCount:
        sorted.where((record) => record.isPowerSample).length,
    avgTemperature: tempCount == 0 ? null : sumTemp / tempCount,
    minTemperature: tempCount == 0 ? null : minTemp,
    maxTemperature: tempCount == 0 ? null : maxTemp,
    milliampHours: _sessionMilliampHours(sorted),
  );
}

/// 会话估算放电量（mAh）：对**有效功耗样本**（[BatteryHistoryRecord.isPowerSample]）
/// 按时间做梯形积分 `∫ current(mA) dt(h)`。派生展示量，非 Scene 表字段。
double _sessionMilliampHours(List<BatteryHistoryRecord> sorted) {
  final samples = <BatteryHistoryRecord>[
    for (final record in sorted)
      if (record.isPowerSample) record,
  ];
  var mah = 0.0;
  for (var i = 1; i < samples.length; i++) {
    final dtHours =
        (_timeMsOf(samples[i]) - _timeMsOf(samples[i - 1])) / 3600000.0;
    if (dtHours <= 0) continue;
    final avgCurrent = (samples[i].current + samples[i - 1].current) / 2;
    mah += avgCurrent * dtHours;
  }
  return mah;
}

/// 记录时间戳（ms）；不可解析时为 `0`。
int _timeMsOf(BatteryHistoryRecord record) =>
    int.tryParse(record.time.trim()) ?? 0;

// ==================== 格式化（纯函数） ====================

/// 毫秒 → `1 小时 2 分` / `3 分 4 秒` / `5 秒`；非正 → `—`。
String _formatDurationMs(int ms) {
  if (ms <= 0) return '—';
  final duration = Duration(milliseconds: ms);
  final hours = duration.inHours;
  final minutes = duration.inMinutes % 60;
  final seconds = duration.inSeconds % 60;
  if (hours > 0) return '$hours 小时 $minutes 分';
  if (minutes > 0) return '$minutes 分 $seconds 秒';
  return '$seconds 秒';
}

/// 时间戳（ms）→ `MM-dd HH:mm:ss`（本地时区）；非正 / 不可解析 → `—`。
String _formatClockTime(int ms) {
  if (ms <= 0) return '—';
  String two(int value) => value.toString().padLeft(2, '0');
  final time = DateTime.fromMillisecondsSinceEpoch(ms);
  return '${two(time.month)}-${two(time.day)} '
      '${two(time.hour)}:${two(time.minute)}:${two(time.second)}';
}

/// 温度（℃）→ 一位小数；`null` → `—`。
String _formatTemp(double? value) =>
    value == null ? '—' : '${value.toStringAsFixed(1)} °C';
