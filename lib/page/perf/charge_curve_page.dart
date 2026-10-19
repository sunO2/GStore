/// 充电曲线页（plan todo 22 / Scene 充电三图等价物）。
///
/// 数据源 = todo-21 的 [ChargeHistoryStore]（**复用，不新建 store/引擎**），
/// 采样行 = [ChargeRecord]（Scene `charge8.records` 列逐字移植）。
///
/// ## 三图（task-33 逐字 SQL 口径）
/// Scene 的三条查询均为
/// `select capacity, <metric>, time ... order by time`（见
/// `.omo/evidence/task-33-scene-data-schema.md`），即三张图**横轴均为容量 (%)**，
/// 纵轴分别为：
/// 1. **电流** `current`（mA）—— `select capacity,current,time`；
/// 2. **温度** `temperature`（℃）—— `select capacity,temperature,time`；
/// 3. **功率** `power = current*voltage/1000`—— `select capacity,(...),time`。
///
/// 说明：plan 文字记为「电流-容量 / 温度-容量 / 时间-容量」，其中第三张与
/// todo 33 的第三序列（`capacity+power+time`）对应；本页第三图以**功率**为纵轴、
/// 时间用于样本排序（详见证据）。功率单位在 task-33 标 `unverified`（Scene CSV
/// 标 `Power(mW)` 却对 `mA×V` 再 `/1000`），故此处只标注「单位 unverified」，
/// 不写入任何断言。
///
/// ## 约定
/// 颜色 / 文字走 [Theme] 令牌，间距 / 半径走设计令牌；loading 用 [AppLoading]；
/// 图表复用无第三方依赖的 [LineChart]（AGENTS.md）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';

import 'package:gstore/compent/line_chart.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/perf/charge_history.dart';
import 'package:gstore/core/perf/charge_history_store.dart';

/// 取某会话的记录，按**容量升序**（同容量按时间升序）排列——即「某指标-容量」曲线的
/// 样本序（Scene 三图横轴为容量）。
///
/// 纯函数：同一输入恒产出同一结果；不属于该会话的记录被过滤掉。
List<ChargeRecord> chargeCurveSeries(
  List<ChargeRecord> records, {
  required int session,
}) {
  final filtered = <ChargeRecord>[
    for (final record in records)
      if (record.session == session) record,
  ];
  filtered.sort((a, b) {
    final byCapacity = a.capacity.compareTo(b.capacity);
    if (byCapacity != 0) return byCapacity;
    return a.time.compareTo(b.time);
  });
  return filtered;
}

/// 充电曲线页面。
///
/// [store] 为可选注入：生产传 `null` → 用 [SharedPrefsChargeHistoryStore]；
/// 测试注入 [InMemoryChargeHistoryStore] 避开 `shared_preferences` 平台通道。
/// 读取失败一律降级为空列表（store 自身静默），页面不抛出。
class ChargeCurvePage extends StatefulWidget {
  const ChargeCurvePage({super.key, this.store});

  /// 充电历史存储；`null` 时用生产 [SharedPrefsChargeHistoryStore]。
  final ChargeHistoryStore? store;

  @override
  State<ChargeCurvePage> createState() => _ChargeCurvePageState();
}

class _ChargeCurvePageState extends State<ChargeCurvePage> {
  late final ChargeHistoryStore _store;

  bool _loading = true;
  List<ChargeRecord> _records = const <ChargeRecord>[];

  /// 当前选中会话；`null` = 取最新会话。
  int? _selectedSession;

  @override
  void initState() {
    super.initState();
    _store = widget.store ?? const SharedPrefsChargeHistoryStore();
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
      final sessions = _sessionsByRecency;
      if (sessions.isEmpty) {
        _selectedSession = null;
      } else if (_selectedSession == null ||
          !sessions.any((s) => s.session == _selectedSession)) {
        _selectedSession = sessions.first.session;
      }
    });
  }

  /// 会话摘要（按结束时间降序，最新在前）。
  List<ChargeSession> get _sessionsByRecency {
    final sessions = summarizeChargeSessions(_records);
    sessions.sort((a, b) {
      final byEnd = b.endTime.compareTo(a.endTime);
      if (byEnd != 0) return byEnd;
      return b.session.compareTo(a.session);
    });
    return sessions;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('充电曲线'),
        actions: [
          IconButton(
            key: const Key('charge_curve_refresh'),
            tooltip: '刷新',
            onPressed: _loading ? null : _reload,
            icon: const Icon(TablerIcons.refresh, size: AppTypography.iconMD),
          ),
        ],
      ),
      body: _loading ? const Center(child: AppLoading()) : _content(context),
    );
  }

  Widget _content(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final sessions = _sessionsByRecency;
    final selected = sessions.isEmpty
        ? null
        : sessions.firstWhere(
            (s) => s.session == _selectedSession,
            orElse: () => sessions.first,
          );
    final series = selected == null
        ? const <ChargeRecord>[]
        : chargeCurveSeries(_records, session: selected.session);

    final currentValues = <double>[for (final r in series) r.current.toDouble()];
    final temperatureValues = <double>[for (final r in series) r.temperature];
    final powerValues = <double>[for (final r in series) r.power];
    final capacityRange = series.isEmpty
        ? null
        : '${series.first.capacity} ~ ${series.last.capacity}%';

    return ListView(
      padding: AppSpacing.horizontalLG_bottomLG,
      children: [
        if (sessions.isNotEmpty && sessions.length > 1) ...[
          _sessionPicker(context, theme, sessions, selected),
          const SizedBox(height: AppSpacing.md),
        ],
        if (series.isEmpty) ...[
          _emptyNotice(context, theme),
          const SizedBox(height: AppSpacing.md),
        ],
        _chartCard(
          context,
          theme,
          key: const Key('charge_curve_chart_current'),
          title: '电流 · 容量',
          unit: 'mA',
          color: scheme.primary,
          values: currentValues,
          capacityRange: capacityRange,
        ),
        const SizedBox(height: AppSpacing.md),
        _chartCard(
          context,
          theme,
          key: const Key('charge_curve_chart_temperature'),
          title: '温度 · 容量',
          unit: '℃',
          color: scheme.tertiary,
          values: temperatureValues,
          capacityRange: capacityRange,
        ),
        const SizedBox(height: AppSpacing.md),
        _chartCard(
          context,
          theme,
          key: const Key('charge_curve_chart_power'),
          title: '功率 · 容量',
          unit: '单位 unverified',
          color: scheme.secondary,
          values: powerValues,
          capacityRange: capacityRange,
        ),
        const SizedBox(height: AppSpacing.xxl),
      ],
    );
  }

  // ==================== 会话选择 ====================

  Widget _sessionPicker(
    BuildContext context,
    ThemeData theme,
    List<ChargeSession> sessions,
    ChargeSession? selected,
  ) {
    // 受控 DropdownButton（`value` 随 state 更新）——DropdownButtonFormField 的
    // `initialValue` 只在首帧生效，切换会话不会刷新显示，故此处用受控组件。
    return InputDecorator(
      decoration: const InputDecoration(
        labelText: '充电会话',
        isDense: true,
        border: OutlineInputBorder(),
      ),
      child: DropdownButton<int>(
        key: const Key('charge_curve_session_picker'),
        value: selected?.session,
        isExpanded: true,
        underline: const SizedBox.shrink(),
        items: [
          for (final session in sessions)
            DropdownMenuItem<int>(
              value: session.session,
              child: Text(
                '会话 ${session.session} · '
                    '${_formatClockTime(session.startTime)}',
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
        onChanged: (value) {
          if (value != null) setState(() => _selectedSession = value);
        },
      ),
    );
  }

  // ==================== 空状态 ====================

  Widget _emptyNotice(BuildContext context, ThemeData theme) {
    final scheme = theme.colorScheme;
    return Card(
      key: const Key('charge_curve_empty'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: AppSpacing.allLG,
        child: Row(
          children: [
            Icon(
              TablerIcons.bolt,
              size: AppTypography.iconMD,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                '暂无充电记录。充电时开启采样后，此处按会话绘制'
                '电流 / 温度 / 功率随容量的曲线。',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ==================== 图表卡 ====================

  Widget _chartCard(
    BuildContext context,
    ThemeData theme, {
    required Key key,
    required String title,
    required String unit,
    required Color color,
    required List<double> values,
    String? capacityRange,
  }) {
    final scheme = theme.colorScheme;
    return Card(
      key: key,
      margin: EdgeInsets.zero,
      child: Padding(
        padding: AppSpacing.allLG,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  TablerIcons.chart_line,
                  size: AppTypography.iconMD,
                  color: color,
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    title,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: AppTypography.weightSemiBold,
                    ),
                  ),
                ),
                Text(
                  unit,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            LineChart(
              values: values,
              color: color,
              gridLines: 3,
              height: AppSpacing.massive,
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              capacityRange == null ? '横轴：容量 (%)' : '横轴：容量 $capacityRange',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 时间戳（ms）→ `MM-dd HH:mm`（本地时区）；非正 / 不可解析 → `—`。
String _formatClockTime(int ms) {
  if (ms <= 0) return '—';
  String two(int value) => value.toString().padLeft(2, '0');
  final time = DateTime.fromMillisecondsSinceEpoch(ms);
  return '${two(time.month)}-${two(time.day)} '
      '${two(time.hour)}:${two(time.minute)}';
}
