/// 性能监控页「第三方应用」区（Shizuku 逐应用 CPU / 内存 / 帧卡顿）。
///
/// * 状态行：Shizuku 可用 / 需要授权（经 [AppDialogs] 提示，非裸弹框）；
/// * 应用选择：按钮 → [AppSheet] 内可搜索列表（复用 `installed_apps`）；
/// * 指标：CPU% / 内存 PSS / Jank% / FPS（由 frame_count 差值推导）折线图 + 数值；
/// * 「实时」开关：Timer 采样流（默认 OFF），可取消；卸载时取消订阅。
///
/// 全部颜色 / 文字走 [Theme] 令牌，间距 / 圆角走设计令牌（AGENTS.md）；
/// 失败一律降级展示，绝不向 UI 抛异常。
library;

import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';

import 'package:gstore/compent/line_chart.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/perf/frame_stats.dart';
import 'package:gstore/core/perf/perf_alert_notifier.dart';
import 'package:gstore/core/perf/perf_alert_service.dart';
import 'package:gstore/core/perf/perf_alert_settings.dart';
import 'package:gstore/core/perf/perf_interval_store.dart';
import 'package:gstore/core/perf/perf_target_store.dart';
import 'package:gstore/core/perf/third_party_perf_service.dart';
import 'package:gstore/core/rust/perf/PerfContract.dart';

/// 滚动序列容量（≈2 分钟 @2s）。
const int _kSeriesCapacity = 60;

/// 可选的实时采样间隔（秒）；默认 [_kDefaultIntervalSeconds]。
const List<int> _kIntervalOptions = <int>[1, 2, 5, 10];

/// 默认采样间隔（秒）。
const int _kDefaultIntervalSeconds = 2;

/// 第三方应用性能区（可注入 [ThirdPartyPerfService] / [PerfIntervalStore] /
/// [PerfTargetStore] / 告警存储与出口，便于测试）。
class ThirdPartyAppSection extends StatefulWidget {
  const ThirdPartyAppSection({
    super.key,
    this.service,
    this.intervalStore,
    this.targetStore,
    this.alertStore,
    this.alertNotifier,
    this.cpu,
    this.thermal,
    this.frameStats,
  });

  /// 可注入服务；为 `null` 时使用默认（Shizuku + PerfModule.instance）。
  final ThirdPartyPerfService? service;

  /// 可注入采样间隔存储；为 `null` 时使用 `shared_preferences`。
  final PerfIntervalStore? intervalStore;

  /// 可注入「最近第三方目标」存储；为 `null` 时使用 `shared_preferences`。
  final PerfTargetStore? targetStore;

  /// 可注入告警设置存储；为 `null` 时使用 `shared_preferences`。
  final PerfAlertSettingsStore? alertStore;

  /// 可注入告警出口；为 `null` 时使用 [LocalPerfAlertNotifier]。
  final PerfAlertNotifier? alertNotifier;

  /// 设备 CPU 报告（由外层页面注入；`null` 时不评估 CPU 告警）。
  final CpuReport? cpu;

  /// 设备温度报告（由外层页面注入；`null` 时不评估温度告警）。
  final ThermalReport? thermal;

  /// 帧统计快照（由外层页面注入；`null` 时仅用第三方指标评估 Jank/FPS）。
  final FrameStats? frameStats;

  @override
  State<ThirdPartyAppSection> createState() => _ThirdPartyAppSectionState();
}

class _ThirdPartyAppSectionState extends State<ThirdPartyAppSection> {
  late final ThirdPartyPerfService _service;
  late final PerfIntervalStore _intervalStore;
  late final PerfTargetStore _targetStore;
  late final PerfAlertSettingsStore _alertStore;
  late final PerfAlertDispatcher _alertDispatcher;

  ShizukuStatus _status = ShizukuStatus.unknown;
  bool _checkingShizuku = false;
  bool _loadingApps = false;
  List<AppTarget> _apps = const <AppTarget>[];
  AppTarget? _target;

  /// 从持久化恢复、等待应用列表就绪后预选的最近目标（尚未匹配到已安装应用）。
  PerfPinnedTarget? _pendingPinned;

  bool _live = false;
  bool _samplingOnce = false;
  StreamSubscription<ThirdPartySample>? _sub;
  ThirdPartyAppMetrics? _last;

  /// 启动耗时测量是否进行中（禁用按钮 + 显示 [AppLoading]）。
  bool _measuringStartup = false;

  /// 最近一次启动耗时测量结果；未测量为 `null`。
  PerfStartupResult? _startup;

  /// TotalTime 历史（有界滚动），用于折线图。
  final List<double> _startupTotals = <double>[];

  /// 告警设置（默认关闭；经 [_alertStore] 持久化）。
  PerfAlertSettings _alertSettings = PerfAlertSettings.defaults;

  // 手动采样的 FPS / 网络速率差值基线。
  int? _prevFrameCount;
  int? _prevTsMs;
  int? _prevRxBytes;
  int? _prevTxBytes;

  /// 实时采样间隔（秒）；经 `watch(interval)` 与手动采样节拍共用。
  int _intervalSeconds = _kDefaultIntervalSeconds;

  final List<double> _cpuSeries = <double>[];
  final List<double> _memSeries = <double>[];
  final List<double> _jankSeries = <double>[];
  final List<double> _fpsSeries = <double>[];
  final List<double> _rxSeries = <double>[];
  final List<double> _txSeries = <double>[];

  bool get _available => _status == ShizukuStatus.available;

  @override
  void initState() {
    super.initState();
    _service = widget.service ?? ThirdPartyPerfService();
    _intervalStore = widget.intervalStore ?? const SharedPrefsPerfIntervalStore();
    _targetStore = widget.targetStore ?? const SharedPrefsPerfTargetStore();
    _alertStore = widget.alertStore ?? const SharedPrefsPerfAlertSettingsStore();
    _alertDispatcher = PerfAlertDispatcher(
      notifier: widget.alertNotifier ?? LocalPerfAlertNotifier(),
    );
    _restoreInterval();
    _restoreTarget();
    _restoreAlertSettings();
    _refreshShizuku();
    _loadApps();
  }

  /// 从持久化恢复告警设置；失败 / 无记录保持默认（关闭）。
  ///
  /// 恢复后若告警已启用且已有采样数据，立即评估一次（Dashboard 冷启动即生效）。
  Future<void> _restoreAlertSettings() async {
    final saved = await _alertStore.load();
    if (!mounted || saved == null) return;
    setState(() => _alertSettings = saved);
    if (saved.enabled) _evaluateAlerts(_last);
  }

  /// 从持久化恢复采样间隔（仅当为受支持选项时），失败 / 无记录保持默认 2s。
  Future<void> _restoreInterval() async {
    final saved = await _intervalStore.load();
    if (!mounted || saved == null) return;
    if (!_kIntervalOptions.contains(saved) || saved == _intervalSeconds) return;
    setState(() => _intervalSeconds = saved);
    if (_live) _startLive();
  }

  /// 从持久化恢复「最近选择的第三方目标」，待应用列表就绪后在已安装应用里
  /// 匹配并预选；读取失败 / 无记录 / 应用已卸载一律静默忽略。
  Future<void> _restoreTarget() async {
    final PerfPinnedTarget? saved;
    try {
      saved = await _targetStore.load();
    } catch (error) {
      debugPrint('[PerfTargetStore] 读取最近目标失败（忽略）: $error');
      return;
    }
    if (!mounted || saved == null || saved.package.isEmpty) return;
    _pendingPinned = saved;
    _tryPreselect();
  }

  /// 应用列表就绪后，把 [_pendingPinned] 匹配到已安装应用并预选。
  ///
  /// 仅当该包名仍在 [_apps] 中时生效（应用已卸载 → 保持未选择）。
  void _tryPreselect() {
    final pinned = _pendingPinned;
    if (pinned == null || _apps.isEmpty || !mounted) return;
    for (final app in _apps) {
      if (app.package == pinned.package) {
        _pendingPinned = null;
        setState(() => _target = app);
        return;
      }
    }
  }

  /// 持久化最近选择的目标；失败静默（不阻塞 UI）。
  Future<void> _persistTarget(AppTarget target) async {
    try {
      await _targetStore.save(
        PerfPinnedTarget(
          package: target.package,
          label: target.label,
          isSystem: target.isSystem,
        ),
      );
    } catch (error) {
      debugPrint('[PerfTargetStore] 保存最近目标失败（忽略）: $error');
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    _sub = null;
    super.dispose();
  }

  // ==================== 数据动作 ====================

  Future<void> _refreshShizuku() async {
    setState(() => _checkingShizuku = true);
    final ok = await _service.refreshShizukuStatus();
    if (!mounted) return;
    setState(() {
      _checkingShizuku = false;
      _status = _service.shizukuStatus;
    });
    if (!ok) _stopLive();
  }

  Future<void> _authorize() async {
    setState(() => _checkingShizuku = true);
    final ok = await _service.ensureShizuku();
    if (!mounted) return;
    setState(() {
      _checkingShizuku = false;
      _status = _service.shizukuStatus;
    });
    if (ok) {
      await _loadApps();
    } else {
      AppDialogs.showError('未能获得 Shizuku 授权，请确认 Shizuku 正在运行并允许本应用');
    }
  }

  Future<void> _loadApps() async {
    if (_loadingApps) return;
    setState(() => _loadingApps = true);
    final apps = await _service.listInstalledApps();
    if (!mounted) return;
    setState(() {
      _apps = apps;
      _loadingApps = false;
    });
    // 应用列表就绪后尝试预选持久化的最近目标。
    _tryPreselect();
  }

  Future<void> _pickApp() async {
    if (_apps.isEmpty && !_loadingApps) {
      await _loadApps();
    }
    if (!mounted) return;
    final selected = await AppSheet.showCustom<AppTarget>(
      context: context,
      builder: (_) => _AppPickerSheet(apps: _apps),
    );
    if (selected == null || !mounted) return;
    setState(() {
      _target = selected;
      _last = null;
      _prevFrameCount = null;
      _prevTsMs = null;
      _prevRxBytes = null;
      _prevTxBytes = null;
      _cpuSeries.clear();
      _memSeries.clear();
      _jankSeries.clear();
      _fpsSeries.clear();
      _rxSeries.clear();
      _txSeries.clear();
    });
    if (_live) _startLive();
    // 记住本次选择（供下次打开预选 + 「我的」页副标题）。
    _persistTarget(selected);
  }

  Future<void> _sampleOnce() async {
    final target = _target;
    if (target == null) return;
    setState(() => _samplingOnce = true);
    final sample = await _service.sampleDetailed(
      target.package,
      prevFrameCount: _prevFrameCount,
      prevTsMs: _prevTsMs,
      prevRxBytes: _prevRxBytes,
      prevTxBytes: _prevTxBytes,
    );
    if (!mounted) return;
    setState(() {
      _samplingOnce = false;
      _prevFrameCount = sample.metrics.frameCount;
      _prevTsMs = sample.tsMs;
      _applySample(sample.metrics);
    });
  }

  /// 冷 / 热启动测量：先经 [AppDialogs.showConfirmSheet] 显式确认（**控制动作**：
  /// 会强制停止并拉起目标应用），再调用服务测量；结果写入 [_startup] 并追加
  /// [_startupTotals]（用于折线图）。失败 / 取消一律安全降级，绝不抛异常。
  Future<void> _measureStartup({required bool cold}) async {
    final target = _target;
    if (target == null) {
      AppDialogs.showInfo('请先选择要监控的应用');
      return;
    }
    if (!_available) {
      AppDialogs.showWarning('需要 Shizuku 授权后才能测量启动耗时');
      return;
    }
    if (_measuringStartup) return;
    final confirmed = await AppDialogs.showConfirmSheet(
      title: cold ? '测量冷启动？' : '测量热启动？',
      message: '将强制停止并重新拉起「${target.label}」，期间该应用会短暂中断。确定继续？',
      confirmText: '开始测量',
      cancelText: '取消',
      isDangerous: true,
      icon: const Icon(TablerIcons.rocket),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _measuringStartup = true);
    final result = await _service.measureStartup(target.package, cold: cold);
    if (!mounted) return;
    setState(() {
      _measuringStartup = false;
      if (result != null) {
        _startup = result;
        final total = result.totalTimeMs;
        if (total != null && total > 0) {
          _startupTotals.add(total.toDouble());
          final excess = _startupTotals.length - _kSeriesCapacity;
          if (excess > 0) _startupTotals.removeRange(0, excess);
        }
      }
    });
    if (result == null) {
      AppDialogs.showError('启动耗时测量失败，请确认 Shizuku 授权与目标应用可启动');
    }
  }

  void _toggleLive(bool on) {
    if (on) {
      if (_target == null) {
        AppDialogs.showInfo('请先选择要监控的应用');
        return;
      }
      if (!_available) {
        AppDialogs.showWarning('需要 Shizuku 授权后才能实时采样第三方应用');
        return;
      }
      _startLive();
      setState(() => _live = true);
    } else {
      _stopLive();
      if (mounted) setState(() => _live = false);
    }
  }

  void _startLive() {
    final target = _target;
    if (target == null) return;
    _sub?.cancel();
    _sub = _service
        .watch(target.package, interval: Duration(seconds: _intervalSeconds))
        .listen(_onStreamSample);
  }

  /// 切换采样间隔；实时中则立即用新间隔重启采样流，并持久化选择。
  void _setInterval(int seconds) {
    if (seconds == _intervalSeconds) return;
    setState(() => _intervalSeconds = seconds);
    _intervalStore.save(seconds);
    if (_live) _startLive();
  }

  void _stopLive() {
    _sub?.cancel();
    _sub = null;
    if (mounted && _live) setState(() => _live = false);
  }

  void _onStreamSample(ThirdPartySample sample) {
    if (!mounted) return;
    setState(() => _applySample(sample.metrics));
  }

  void _applySample(ThirdPartyAppMetrics metrics) {
    _last = metrics;
    _push(_cpuSeries, metrics.cpuPercent);
    _push(_memSeries, _pssMb(metrics));
    _push(_jankSeries, metrics.jankyPercent);
    _push(_fpsSeries, metrics.fps);
    _push(_rxSeries, metrics.rxBytesPerSec);
    _push(_txSeries, metrics.txBytesPerSec);
    // 维护手动采样的网络差值基线（实时流由服务内部维护）。
    _prevRxBytes = metrics.net?.rxBytes;
    _prevTxBytes = metrics.net?.txBytes;
    // 每次采样后按当前阈值评估并派发告警（节流 + 去重在后端）。
    _evaluateAlerts(metrics);
  }

  // ==================== 告警 ====================

  /// 用最新报告评估阈值告警并（节流地）派发。
  ///
  /// 设备侧报告（[ThirdPartyAppSection.cpu] / `thermal` / `frameStats`）由外层
  /// 页面注入，可为 `null`（模块不可用是预期状态）；第三方指标来自 [metrics]。
  /// 卸载后不再派发（`mounted` 守卫），异常一律由派发器吞掉。
  void _evaluateAlerts(ThirdPartyAppMetrics? metrics) {
    if (!mounted || !_alertSettings.enabled) return;
    final alerts = evaluate(
      cpu: widget.cpu,
      thermal: widget.thermal,
      frames: widget.frameStats,
      thirdParty: metrics,
      settings: _alertSettings,
    );
    if (alerts.isEmpty) return;
    unawaited(
      _alertDispatcher.dispatch(alerts, settings: _alertSettings),
    );
  }

  /// 更新并持久化告警设置；启用时立即评估一次。
  void _setAlertSettings(PerfAlertSettings next) {
    setState(() => _alertSettings = next);
    _alertStore.save(next);
    if (next.enabled) _evaluateAlerts(_last);
  }

  /// 打开阈值编辑弹层（统一底部弹层），保存后写回设置。
  Future<void> _editThreshold({
    required String title,
    required double initial,
    required String unit,
    required String hint,
    required PerfAlertSettings Function(double value) apply,
  }) async {
    final result = await AppSheet.showCustom<double>(
      context: context,
      builder: (_) => _PerfThresholdSheet(
        title: title,
        initial: initial,
        unit: unit,
        hint: hint,
      ),
    );
    if (result == null || !mounted) return;
    _setAlertSettings(apply(result));
  }

  static double? _pssMb(ThirdPartyAppMetrics metrics) {
    final pssKb = metrics.memPssKb;
    if (pssKb == null) return null;
    return pssKb / 1024.0;
  }

  static void _push(List<double> series, double? value) {
    if (value == null || !value.isFinite) return;
    series.add(value);
    final excess = series.length - _kSeriesCapacity;
    if (excess > 0) series.removeRange(0, excess);
  }

  // ==================== 视图 ====================

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: AppSpacing.allLG,
      child: Padding(
        padding: AppSpacing.allLG,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _header(context),
            const SizedBox(height: AppSpacing.md),
            _statusRow(context),
            const SizedBox(height: AppSpacing.md),
            _pickerRow(context),
            if (_target != null) ...[
              const Divider(height: AppSpacing.xxl),
              _liveRow(context),
              const SizedBox(height: AppSpacing.md),
              _intervalRow(context),
              const SizedBox(height: AppSpacing.md),
              _metricsCharts(context, theme),
              const SizedBox(height: AppSpacing.md),
              _metricsValues(context, theme),
              const SizedBox(height: AppSpacing.md),
              _memoryBreakdownCard(context, theme),
              const SizedBox(height: AppSpacing.md),
              _renderBreakdownCard(context, theme),
              const SizedBox(height: AppSpacing.md),
              _powerCard(context, theme),
              const SizedBox(height: AppSpacing.md),
              _processCard(context, theme),
              const SizedBox(height: AppSpacing.md),
              _networkCard(context, theme),
              const SizedBox(height: AppSpacing.md),
              _appInfoCard(context, theme),
              const SizedBox(height: AppSpacing.md),
              _smapsCard(context, theme),
              const SizedBox(height: AppSpacing.md),
              _foregroundCard(context, theme),
              const SizedBox(height: AppSpacing.md),
              _crashCard(context, theme),
              const SizedBox(height: AppSpacing.md),
              _wakeLockCard(context, theme),
            ],
            const SizedBox(height: AppSpacing.md),
            _startupCard(context, theme),
            const SizedBox(height: AppSpacing.md),
            _alertCard(context, theme),
          ],
        ),
      ),
    );
  }

  Widget _header(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Icon(
          TablerIcons.apps,
          size: AppTypography.iconMD,
          color: theme.colorScheme.primary,
        ),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Text(
            '第三方应用',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: AppTypography.weightSemiBold,
            ),
          ),
        ),
        if (_target != null)
          IconButton(
            key: const Key('perf_third_party_sample'),
            tooltip: '采样一次',
            onPressed: _samplingOnce || !_available ? null : _sampleOnce,
            icon: _samplingOnce
                ? const AppLoading(size: AppLoadingSize.small)
                : const Icon(TablerIcons.refresh, size: AppTypography.iconMD),
          ),
      ],
    );
  }

  Widget _statusRow(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final (IconData icon, String title, String subtitle, Color color) =
        switch (_status) {
      ShizukuStatus.available => (
          TablerIcons.shield_filled,
          'Shizuku 已授权',
          '可读取任意应用 CPU / 内存 / 帧卡顿',
          scheme.primary,
        ),
      ShizukuStatus.permissionDenied => (
          TablerIcons.shield,
          '需要 Shizuku',
          '本应用尚未获得 Shizuku 授权',
          scheme.error,
        ),
      ShizukuStatus.binderUnavailable => (
          TablerIcons.shield,
          '需要 Shizuku',
          'Shizuku 未运行，请先在 Shizuku 应用中启动',
          scheme.error,
        ),
      ShizukuStatus.unknown => (
          TablerIcons.shield,
          '正在检查 Shizuku…',
          '正在检测 Shizuku 服务状态',
          scheme.onSurfaceVariant,
        ),
    };
    return Container(
      padding: AppSpacing.allMD,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: AppRadius.allMD,
      ),
      child: Row(
        children: [
          Icon(icon, size: AppTypography.iconMD, color: color),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: AppTypography.weightSemiBold,
                  ),
                ),
                Text(
                  subtitle,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          if (_checkingShizuku)
            const AppLoading(size: AppLoadingSize.small)
          else if (!_available)
            TextButton(
              key: const Key('perf_third_party_authorize'),
              onPressed: _authorize,
              child: const Text('授权 / 检查'),
            ),
        ],
      ),
    );
  }

  Widget _pickerRow(BuildContext context) {
    final theme = Theme.of(context);
    final label = _target?.label ?? '未选择应用';
    final sub = _target?.package ?? '选择要监控的第三方应用';
    return Row(
      children: [
        Icon(
          TablerIcons.apps,
          size: AppTypography.iconMD,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyLarge?.copyWith(
                  fontWeight: AppTypography.weightMedium,
                ),
              ),
              Text(
                sub,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        FilledButton.tonalIcon(
          key: const Key('perf_third_party_pick'),
          onPressed: _loadingApps ? null : _pickApp,
          icon: _loadingApps
              ? const AppLoading(size: AppLoadingSize.small)
              : const Icon(TablerIcons.apps, size: AppTypography.iconSM),
          label: Text(_target == null ? '选择应用' : '更换'),
        ),
      ],
    );
  }

  Widget _liveRow(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Icon(
          TablerIcons.bolt,
          size: AppTypography.iconMD,
          color: theme.colorScheme.tertiary,
        ),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Text(
            _live ? '实时采集中（每 $_intervalSeconds 秒）' : '实时采集（默认关闭）',
            style: theme.textTheme.bodyMedium,
          ),
        ),
        Switch(
          key: const Key('perf_third_party_live_switch'),
          value: _live,
          onChanged: _available ? _toggleLive : null,
        ),
      ],
    );
  }

  /// 采样间隔选择器（1s / 2s / 5s / 10s）；仅在实时采样中可调。
  Widget _intervalRow(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              TablerIcons.clock,
              size: AppTypography.iconMD,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                '采样间隔',
                style: theme.textTheme.bodyMedium,
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        SizedBox(
          width: double.infinity,
          child: AppSegmentedButton<int>(
            key: const Key('perf_third_party_interval'),
            value: _intervalSeconds,
            enabled: _live,
            segments: [
              for (final seconds in _kIntervalOptions)
                AppSegment<int>(
                  value: seconds,
                  label: '${seconds}s',
                  key: Key('perf_third_party_interval_$seconds'),
                ),
            ],
            onChanged: _setInterval,
          ),
        ),
      ],
    );
  }

  // ==================== 扩展卡片 ====================

  /// 启动耗时卡：冷 / 热启动测量（控制动作，需确认）+ 最近结果 + TotalTime 历史。
  ///
  /// 无目标 / Shizuku 不可用时按钮禁用；测量中禁用并显示 [AppLoading]。
  Widget _startupCard(BuildContext context, ThemeData theme) {
    final scheme = theme.colorScheme;
    final result = _startup;
    final canMeasure = _available && _target != null && !_measuringStartup;
    return _infoCard(
      context,
      icon: TablerIcons.rocket,
      title: '启动耗时',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '测量目标应用的冷 / 热启动耗时（会强制停止并拉起目标应用）',
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: [
              Expanded(
                child: FilledButton.tonalIcon(
                  key: const Key('perf_startup_cold'),
                  onPressed:
                      canMeasure ? () => _measureStartup(cold: true) : null,
                  icon: _measuringStartup
                      ? const AppLoading(size: AppLoadingSize.small)
                      : const Icon(
                          TablerIcons.snowflake,
                          size: AppTypography.iconSM,
                        ),
                  label: const Text('测冷启动'),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: FilledButton.tonalIcon(
                  key: const Key('perf_startup_warm'),
                  onPressed:
                      canMeasure ? () => _measureStartup(cold: false) : null,
                  icon: _measuringStartup
                      ? const AppLoading(size: AppLoadingSize.small)
                      : const Icon(
                          TablerIcons.rocket,
                          size: AppTypography.iconSM,
                        ),
                  label: const Text('测温启动'),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          if (result == null)
            _emptyHint(context, '尚未测量')
          else ...[
            Wrap(
              spacing: AppSpacing.xl,
              runSpacing: AppSpacing.md,
              children: [
                _metric(context, 'ThisTime', _startupMsText(result.thisTimeMs)),
                _metric(
                  context,
                  'TotalTime',
                  _startupMsText(result.totalTimeMs),
                ),
                _metric(context, 'WaitTime', _startupMsText(result.waitTimeMs)),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: [
                _badge(
                  context,
                  result.mode == 'warm' ? '热启动' : '冷启动',
                  color: result.mode == 'warm' ? scheme.tertiary : scheme.primary,
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    result.status == null ? '状态未知' : '状态: ${result.status}',
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            _pathRow(context, 'Activity', result.activity),
            const SizedBox(height: AppSpacing.sm),
            LineChart(
              values: List<double>.of(_startupTotals),
              color: scheme.primary,
              minY: 0,
              gridLines: 3,
              height: AppSpacing.huge,
            ),
          ],
        ],
      ),
    );
  }

  /// 启动耗时文本（ms）；`null` → `—`。
  static String _startupMsText(int? ms) => ms == null ? '—' : '$ms ms';

  /// 告警卡：总开关 + 通知/横幅开关 + 当前阈值（点按编辑）。
  Widget _alertCard(BuildContext context, ThemeData theme) {
    final scheme = theme.colorScheme;
    final on = _alertSettings.enabled;
    return _infoCard(
      context,
      icon: TablerIcons.bell,
      title: '告警',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _alertSwitchRow(
            context,
            rowKey: const Key('perf_alert_enabled'),
            title: '启用告警',
            subtitle: '指标越过阈值时提醒',
            value: on,
            onChanged: (value) =>
                _setAlertSettings(_alertSettings.copyWith(enabled: value)),
          ),
          _alertSwitchRow(
            context,
            rowKey: const Key('perf_alert_notify'),
            title: '系统通知',
            subtitle: '在通知栏推送告警',
            value: _alertSettings.notify,
            onChanged: on
                ? (value) =>
                    _setAlertSettings(_alertSettings.copyWith(notify: value))
                : null,
          ),
          _alertSwitchRow(
            context,
            rowKey: const Key('perf_alert_banner'),
            title: '应用内横幅',
            subtitle: '在当前页面顶部提示',
            value: _alertSettings.banner,
            onChanged: on
                ? (value) =>
                    _setAlertSettings(_alertSettings.copyWith(banner: value))
                : null,
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            on ? '已配置阈值（点按修改）' : '已配置阈值（启用后生效，点按修改）',
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          _thresholdRow(
            context,
            rowKey: const Key('perf_alert_threshold_cpu'),
            label: 'CPU 占用',
            value: '≥ ${_thresholdText(_alertSettings.cpuPercent)}%',
            onTap: () => _editThreshold(
              title: 'CPU 占用阈值',
              initial: _alertSettings.cpuPercent,
              unit: '%',
              hint: '总占用超过该百分比时告警',
              apply: (value) =>
                  _alertSettings.copyWith(cpuPercent: value),
            ),
          ),
          _thresholdRow(
            context,
            rowKey: const Key('perf_alert_threshold_temperature'),
            label: '温度',
            value: '≥ ${_thresholdText(_alertSettings.temperatureC)} °C',
            onTap: () => _editThreshold(
              title: '温度阈值',
              initial: _alertSettings.temperatureC,
              unit: '°C',
              hint: '最高温度超过该值时告警',
              apply: (value) =>
                  _alertSettings.copyWith(temperatureC: value),
            ),
          ),
          _thresholdRow(
            context,
            rowKey: const Key('perf_alert_threshold_jank'),
            label: 'Jank 比例',
            value: '≥ ${_thresholdText(_alertSettings.jankPercent)}%',
            onTap: () => _editThreshold(
              title: 'Jank 比例阈值',
              initial: _alertSettings.jankPercent,
              unit: '%',
              hint: '卡顿帧占比超过该百分比时告警',
              apply: (value) =>
                  _alertSettings.copyWith(jankPercent: value),
            ),
          ),
          _thresholdRow(
            context,
            rowKey: const Key('perf_alert_threshold_fps'),
            label: '最低帧率',
            value: '< ${_thresholdText(_alertSettings.minFps)} fps',
            onTap: () => _editThreshold(
              title: '最低帧率阈值',
              initial: _alertSettings.minFps,
              unit: 'fps',
              hint: '帧率低于该值时告警',
              apply: (value) => _alertSettings.copyWith(minFps: value),
            ),
          ),
        ],
      ),
    );
  }

  Widget _alertSwitchRow(
    BuildContext context, {
    required Key rowKey,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool>? onChanged,
  }) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: theme.textTheme.bodyMedium),
              Text(
                subtitle,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        Switch(key: rowKey, value: value, onChanged: onChanged),
      ],
    );
  }

  Widget _thresholdRow(
    BuildContext context, {
    required Key rowKey,
    required String label,
    required String value,
    required VoidCallback onTap,
  }) {
    final theme = Theme.of(context);
    return InkWell(
      key: rowKey,
      onTap: onTap,
      borderRadius: AppRadius.allSM,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: theme.textTheme.bodyMedium,
              ),
            ),
            Text(
              value,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: AppTypography.weightSemiBold,
              ),
            ),
            const SizedBox(width: AppSpacing.xs),
            Icon(
              TablerIcons.edit,
              size: AppTypography.iconSM,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }

  /// 阈值展示文本：整数去掉小数尾零，其余保留 1 位。
  static String _thresholdText(double value) {
    if (!value.isFinite) return '—';
    if (value == value.roundToDouble()) return value.toStringAsFixed(0);
    return value.toStringAsFixed(1);
  }

  /// 通用信息卡头（图标 + 标题 + 内容），全走主题令牌。
  Widget _infoCard(
    BuildContext context, {
    required IconData icon,
    required String title,
    required Widget child,
  }) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: AppSpacing.allMD,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: AppRadius.allMD,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                icon,
                size: AppTypography.iconSM,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  title,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: AppTypography.weightSemiBold,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          child,
        ],
      ),
    );
  }

  /// 空态提示文案。
  Widget _emptyHint(BuildContext context, [String text = '等待数据']) {
    final theme = Theme.of(context);
    return Text(
      text,
      style: theme.textTheme.bodyMedium?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }

  /// 内存细分卡（App Summary：Java / Native / Code / Stack / Graphics /
  /// Private Other / System / Total PSS）。
  Widget _memoryBreakdownCard(BuildContext context, ThemeData theme) {
    final mem = _last?.memSummary;
    return _infoCard(
      context,
      icon: TablerIcons.database,
      title: '内存细分',
      child: mem == null
          ? _emptyHint(context)
          : Wrap(
              spacing: AppSpacing.xl,
              runSpacing: AppSpacing.md,
              children: [
                _metric(context, 'Java 堆', _kbText(mem.javaHeapKb)),
                _metric(context, 'Native 堆', _kbText(mem.nativeHeapKb)),
                _metric(context, 'Code', _kbText(mem.codeKb)),
                _metric(context, 'Stack', _kbText(mem.stackKb)),
                _metric(context, 'Graphics', _kbText(mem.graphicsKb)),
                _metric(context, 'Private Other', _kbText(mem.privateOtherKb)),
                _metric(context, 'System', _kbText(mem.systemKb)),
                _metric(context, 'Total PSS', _kbText(mem.totalPssKb)),
              ],
            ),
    );
  }

  /// 渲染细分卡（`gfxinfo ... framestats`：FPS / Jank / 帧数 / 平均与百分位
  /// 总耗时 / UI-Draw-GPU 阶段均值）；`render` 缺失时整卡「不可用」。
  Widget _renderBreakdownCard(BuildContext context, ThemeData theme) {
    final render = _last?.render;
    return _infoCard(
      context,
      icon: TablerIcons.gauge,
      title: '渲染细分',
      child: render == null
          ? _emptyHint(context, '渲染细分不可用')
          : Wrap(
              spacing: AppSpacing.xl,
              runSpacing: AppSpacing.md,
              children: [
                _metric(context, 'FPS', _decimalOrUnavailable(render.fps, 1)),
                _metric(context, 'Jank 帧', _intOrUnavailable(render.jankCount)),
                _metric(context, '帧数', _intOrUnavailable(render.frameCount)),
                _metric(context, '平均', _msOrUnavailable(render.avgTotalMs)),
                _metric(context, 'P50', _msOrUnavailable(render.p50TotalMs)),
                _metric(context, 'P90', _msOrUnavailable(render.p90TotalMs)),
                _metric(context, 'P99', _msOrUnavailable(render.p99TotalMs)),
                _metric(context, 'UI', _msOrUnavailable(render.avgUiMs)),
                _metric(context, 'Draw', _msOrUnavailable(render.avgDrawMs)),
                _metric(context, 'GPU', _msOrUnavailable(render.avgGpuMs)),
              ],
            ),
    );
  }

  /// 耗电 / 唤醒卡（`batterystats --charged`：估算 mAh / 唤醒锁时长 /
  /// 组件 mAh）；`power` 缺失时整卡「不可用」。
  Widget _powerCard(BuildContext context, ThemeData theme) {
    final power = _last?.power;
    return _infoCard(
      context,
      icon: TablerIcons.bolt,
      title: '耗电 / 唤醒',
      child: power == null
          ? _emptyHint(context, '耗电数据不可用')
          : Wrap(
              spacing: AppSpacing.xl,
              runSpacing: AppSpacing.md,
              children: [
                _metric(context, '估算耗电', _mahOrUnavailable(power.mah)),
                _metric(context, '唤醒', _wakeOrUnavailable(power.wakeLockMs)),
                _metric(
                  context,
                  '移动网络',
                  _mahOrUnavailable(power.mobileRadioMah),
                ),
                _metric(context, 'Wifi', _mahOrUnavailable(power.wifiMah)),
                _metric(context, '屏幕', _mahOrUnavailable(power.screenMah)),
                _metric(context, 'CPU', _mahOrUnavailable(power.cpuMah)),
              ],
            ),
    );
  }

  /// 进程 / 线程卡：线程数 + 该应用的进程列表（名称 • pid • RSS）。
  Widget _processCard(BuildContext context, ThemeData theme) {
    final metrics = _last;
    final processes = metrics?.processes ?? const <PerfProcessInfo>[];
    return _infoCard(
      context,
      icon: TablerIcons.list_details,
      title: '进程 / 线程',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '线程数',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Text(
                metrics?.threads?.toString() ?? '—',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: AppTypography.weightSemiBold,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          if (processes.isEmpty)
            _emptyHint(context, '暂无进程数据')
          else
            for (final process in processes) _processRow(context, process),
        ],
      ),
    );
  }

  Widget _processRow(BuildContext context, PerfProcessInfo process) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Row(
        children: [
          Expanded(
            child: Text(
              process.name.isEmpty ? '(未知进程)' : process.name,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium,
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Text(
            'pid ${process.pid}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          SizedBox(
            width: AppSpacing.huge * 2,
            child: Text(
              _kbText(process.rssKb),
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

  /// 网络卡：当前接收 / 发送速率 + 双折线历史。
  Widget _networkCard(BuildContext context, ThemeData theme) {
    final scheme = theme.colorScheme;
    final netAvailable = _last?.net != null;
    final hasChart = _rxSeries.isNotEmpty || _txSeries.isNotEmpty;
    return _infoCard(
      context,
      icon: TablerIcons.network,
      title: '网络',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: _rateValue(context, '接收', _last?.rxBytesPerSec,
                    scheme.primary),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: _rateValue(context, '发送', _last?.txBytesPerSec,
                    scheme.tertiary),
              ),
            ],
          ),
          if (!netAvailable && !hasChart) ...[
            const SizedBox(height: AppSpacing.sm),
            _emptyHint(context, '网络数据不可用（部分系统可能不支持）'),
          ],
          const SizedBox(height: AppSpacing.sm),
          _adaptiveTiles(
            context,
            <Widget Function(double width)>[
              (width) => _chartTile(
                    context,
                    width: width,
                    label: '接收速率',
                    value: _rateText(_last?.rxBytesPerSec),
                    color: scheme.primary,
                    values: _rxSeries,
                    minY: 0,
                  ),
              (width) => _chartTile(
                    context,
                    width: width,
                    label: '发送速率',
                    value: _rateText(_last?.txBytesPerSec),
                    color: scheme.tertiary,
                    values: _txSeries,
                    minY: 0,
                  ),
            ],
          ),
        ],
      ),
    );
  }

  // ==================== 应用深入卡片 ====================

  /// 应用信息卡：版本 / SDK / 安装更新时间 / 权限 / 组件 / 系统启用徽章 / 路径。
  Widget _appInfoCard(BuildContext context, ThemeData theme) {
    final info = _last?.appInfo;
    final scheme = theme.colorScheme;
    return _infoCard(
      context,
      icon: TablerIcons.info_circle,
      title: '应用信息',
      child: info == null
          ? _emptyHint(context, '应用信息不可用')
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: AppSpacing.xl,
                  runSpacing: AppSpacing.md,
                  children: [
                    _metric(context, '版本', _versionText(info)),
                    _metric(context, 'SDK', _sdkText(info)),
                    _metric(context, '安装时间', info.firstInstall ?? '—'),
                    _metric(context, '更新时间', info.lastUpdate ?? '—'),
                    _metric(
                      context,
                      '权限 (授予/申请)',
                      '${info.grantedPermissions.length} / '
                          '${info.requestedPermissions.length}',
                    ),
                    _metric(context, '组件 (A/S/R/P)', _componentText(info)),
                  ],
                ),
                const SizedBox(height: AppSpacing.sm),
                Wrap(
                  spacing: AppSpacing.sm,
                  runSpacing: AppSpacing.sm,
                  children: [
                    _badge(context, info.isSystem ? '系统应用' : '非系统应用'),
                    _badge(
                      context,
                      info.enabled ? '已启用' : '已停用',
                      color: info.enabled ? scheme.primary : scheme.error,
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.sm),
                _pathRow(context, '代码路径', info.codePath),
                _pathRow(context, '数据目录', info.dataDir),
              ],
            ),
    );
  }

  /// 精确内存卡（smaps）：PSS / RSS / 共享 / 私有（MB）。
  Widget _smapsCard(BuildContext context, ThemeData theme) {
    final smaps = _last?.smaps;
    return _infoCard(
      context,
      icon: TablerIcons.database,
      title: '精确内存 (smaps)',
      child: smaps == null
          ? _emptyHint(context, 'smaps 不可用')
          : Wrap(
              spacing: AppSpacing.xl,
              runSpacing: AppSpacing.md,
              children: [
                _metric(context, 'PSS', _mbText(smaps.pssKb)),
                _metric(context, 'RSS', _mbText(smaps.rssKb)),
                _metric(context, 'Shared', _mbText(smaps.sharedKb)),
                _metric(context, 'Private Dirty', _mbText(smaps.privateDirtyKb)),
                _metric(context, 'Private Clean', _mbText(smaps.privateCleanKb)),
              ],
            ),
    );
  }

  /// 前台状态卡：前台 / 后台。
  Widget _foregroundCard(BuildContext context, ThemeData theme) {
    final fg = _last?.foreground;
    final scheme = theme.colorScheme;
    final isFg = fg?.isForeground ?? false;
    final color = fg == null
        ? scheme.onSurfaceVariant
        : (isFg ? scheme.primary : scheme.onSurfaceVariant);
    return _infoCard(
      context,
      icon: TablerIcons.eye,
      title: '前台状态',
      child: fg == null
          ? _emptyHint(context, '前台状态不可用')
          : Row(
              children: [
                Icon(
                  isFg ? TablerIcons.eye : TablerIcons.eye_off,
                  size: AppTypography.iconSM,
                  color: color,
                ),
                const SizedBox(width: AppSpacing.sm),
                Text(
                  isFg ? '前台' : '后台',
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: color,
                    fontWeight: AppTypography.weightSemiBold,
                  ),
                ),
              ],
            ),
    );
  }

  /// 崩溃 / ANR 卡：计数 + 最近时间 + 最多 5 条近期记录（kind • time • summary）。
  Widget _crashCard(BuildContext context, ThemeData theme) {
    final crashes = _last?.crashes;
    final recent = crashes == null
        ? const <PerfCrashEntry>[]
        : crashes.recent.take(5).toList(growable: false);
    return _infoCard(
      context,
      icon: TablerIcons.alert_triangle,
      title: '崩溃 / ANR',
      child: crashes == null
          ? _emptyHint(context, '崩溃记录不可用')
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: AppSpacing.xl,
                  runSpacing: AppSpacing.md,
                  children: [
                    _metric(context, '崩溃次数', '${crashes.crashCount}'),
                    _metric(context, 'ANR 次数', '${crashes.anrCount}'),
                    _metric(context, '最近崩溃', crashes.lastCrash ?? '—'),
                    _metric(context, '最近 ANR', crashes.lastAnr ?? '—'),
                  ],
                ),
                if (recent.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: AppSpacing.sm),
                    child: _emptyHint(context, '无近期记录'),
                  )
                else ...[
                  const SizedBox(height: AppSpacing.sm),
                  for (final entry in recent) _crashRow(context, entry),
                ],
              ],
            ),
    );
  }

  /// 唤醒锁明细卡：按持有时长降序，展示 Top-5，其余折叠为合计。
  Widget _wakeLockCard(BuildContext context, ThemeData theme) {
    final locks = _last?.wakeLocks ?? const <PerfWakeLock>[];
    if (locks.isEmpty) {
      return _infoCard(
        context,
        icon: TablerIcons.lock,
        title: '唤醒锁明细',
        child: _emptyHint(context, '无唤醒锁记录'),
      );
    }
    final sorted = List<PerfWakeLock>.of(locks)
      ..sort((a, b) => (b.ms ?? 0).compareTo(a.ms ?? 0));
    const int topN = 5;
    final top = sorted.take(topN).toList(growable: false);
    final rest = sorted.skip(topN).toList(growable: false);
    final restMs = rest.fold<int>(0, (sum, lock) => sum + (lock.ms ?? 0));
    return _infoCard(
      context,
      icon: TablerIcons.lock,
      title: '唤醒锁明细',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final lock in top) _wakeRow(context, lock),
          if (rest.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
              child: Text(
                '其余 ${rest.length} 项合计 ${_durationText(restMs)}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _crashRow(BuildContext context, PerfCrashEntry entry) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _badge(context, entry.kind ?? '—',
                  color: theme.colorScheme.error),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  entry.time ?? '—',
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            entry.summary ?? '—',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Widget _wakeRow(BuildContext context, PerfWakeLock lock) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Row(
        children: [
          Expanded(
            child: Text(
              lock.name ?? '(未知唤醒锁)',
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium,
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Text(
            lock.ms == null ? '—' : _durationText(lock.ms!),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  /// 小徽章（系统/第三方、启用/停用、崩溃类型）；颜色走主题令牌。
  Widget _badge(BuildContext context, String label, {Color? color}) {
    final theme = Theme.of(context);
    final fg = color ?? theme.colorScheme.onSurfaceVariant;
    return Container(
      padding: AppSpacing.chipPadding,
      decoration: BoxDecoration(
        color: fg.withValues(alpha: 0.12),
        borderRadius: AppRadius.allSM,
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(color: fg),
      ),
    );
  }

  /// 带省略号的「标签 : 值」行（用于代码路径 / 数据目录）。
  Widget _pathRow(BuildContext context, String label, String? value) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              value ?? '—',
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }

  /// 版本展示：`name (code)`；缺一取另一个；皆缺 `—`。
  static String _versionText(PerfAppInfo info) {
    final name = info.versionName;
    final code = info.versionCode;
    if (name == null && code == null) return '—';
    if (name == null) return '$code';
    if (code == null) return name;
    return '$name ($code)';
  }

  /// SDK 展示：`target T / min M`；皆缺 `—`。
  static String _sdkText(PerfAppInfo info) {
    final target = info.targetSdk;
    final min = info.minSdk;
    if (target == null && min == null) return '—';
    return 'target ${target ?? '—'} / min ${min ?? '—'}';
  }

  /// 组件计数展示：`A / S / R / P`。
  static String _componentText(PerfAppInfo info) =>
      '${info.activityCount} / ${info.serviceCount} / '
      '${info.receiverCount} / ${info.providerCount}';

  /// KiB → MB（1 位小数）；`null` → `—`。
  static String _mbText(int? kb) =>
      kb == null ? '—' : '${(kb / 1024).toStringAsFixed(1)} MB';

  Widget _rateValue(
    BuildContext context,
    String label,
    double? value,
    Color color,
  ) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          _rateText(value),
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.titleMedium?.copyWith(
            color: value == null ? theme.colorScheme.onSurfaceVariant : color,
            fontWeight: AppTypography.weightSemiBold,
          ),
        ),
      ],
    );
  }

  /// 自适应双列瓦片布局（宽度不足两列时退化为单列）。
  Widget _adaptiveTiles(
    BuildContext context,
    List<Widget Function(double width)> builders,
  ) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const double gap = AppSpacing.md;
        const double minTileWidth = 180;
        final double tileWidth =
            constraints.maxWidth >= minTileWidth * 2 + gap
                ? (constraints.maxWidth - gap) / 2
                : constraints.maxWidth;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [for (final build in builders) build(tileWidth)],
        );
      },
    );
  }

  /// KiB → 人类可读（≥1024 KiB 转 MB）；`null` → `—`。
  static String _kbText(int? kb) {
    if (kb == null) return '—';
    if (kb >= 1024) return '${(kb / 1024).toStringAsFixed(1)} MB';
    return '$kb KB';
  }

  /// 字节/秒 → 人类可读（B/s / KB/s / MB/s）；`null` / 非有限 → `—`。
  static String _rateText(double? bps) {
    if (bps == null || !bps.isFinite) return '—';
    if (bps >= 1024 * 1024) {
      return '${(bps / (1024 * 1024)).toStringAsFixed(2)} MB/s';
    }
    if (bps >= 1024) return '${(bps / 1024).toStringAsFixed(1)} KB/s';
    return '${bps.toStringAsFixed(0)} B/s';
  }

  Widget _metricsCharts(BuildContext context, ThemeData theme) {
    final scheme = theme.colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        const double gap = AppSpacing.md;
        const double minTileWidth = 180;
        final double tileWidth =
            constraints.maxWidth >= minTileWidth * 2 + gap
                ? (constraints.maxWidth - gap) / 2
                : constraints.maxWidth;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            _chartTile(
              context,
              width: tileWidth,
              label: 'CPU',
              value: _last?.cpuPercent == null
                  ? null
                  : '${_last!.cpuPercent!.toStringAsFixed(1)}%',
              color: scheme.primary,
              values: _cpuSeries,
              minY: 0,
              maxY: 100,
            ),
            _chartTile(
              context,
              width: tileWidth,
              label: '内存 PSS',
              value: _last?.memPssKb == null
                  ? null
                  : '${(_last!.memPssKb! / 1024).toStringAsFixed(1)} MB',
              color: scheme.tertiary,
              values: _memSeries,
              minY: 0,
            ),
            _chartTile(
              context,
              width: tileWidth,
              label: 'Jank',
              value: _last?.jankyPercent == null
                  ? null
                  : '${_last!.jankyPercent!.toStringAsFixed(1)}%',
              color: scheme.error,
              values: _jankSeries,
              minY: 0,
              maxY: 100,
            ),
            _chartTile(
              context,
              width: tileWidth,
              label: 'FPS',
              value: _last?.fps == null
                  ? null
                  : _last!.fps!.toStringAsFixed(1),
              color: scheme.secondary,
              values: _fpsSeries,
              minY: 0,
            ),
          ],
        );
      },
    );
  }

  Widget _chartTile(
    BuildContext context, {
    required double width,
    required String label,
    required String? value,
    required Color color,
    required List<double> values,
    double? minY,
    double? maxY,
  }) {
    final theme = Theme.of(context);
    return SizedBox(
      width: width,
      child: Container(
        padding: AppSpacing.allMD,
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: AppRadius.allMD,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              value ?? '等待数据',
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleLarge?.copyWith(
                color: value == null
                    ? theme.colorScheme.onSurfaceVariant
                    : color,
                fontWeight: AppTypography.weightSemiBold,
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            LineChart(
              values: List<double>.of(values),
              color: color,
              minY: minY,
              maxY: maxY,
              gridLines: 3,
              height: AppSpacing.huge,
            ),
          ],
        ),
      ),
    );
  }

  Widget _metricsValues(BuildContext context, ThemeData theme) {
    final m = _last;
    return Wrap(
      spacing: AppSpacing.xl,
      runSpacing: AppSpacing.md,
      children: [
        _metric(context, 'PID', m?.pid?.toString() ?? '—'),
        _metric(context, '帧数', m?.frameCount?.toString() ?? '—'),
        _metric(
          context,
          'Jank 帧',
          m?.jankyFrames?.toString() ?? '—',
          sub: m?.jankyPercent == null
              ? null
              : '${m!.jankyPercent!.toStringAsFixed(1)}%',
        ),
        _metric(context, 'P50', _msText(m?.p50Ms)),
        _metric(context, 'P90', _msText(m?.p90Ms)),
        _metric(context, 'P95', _msText(m?.p95Ms)),
        _metric(context, 'P99', _msText(m?.p99Ms)),
        _metric(context, '掉帧', m?.missedVsync?.toString() ?? '—'),
      ],
    );
  }

  static String _msText(double? value) =>
      value == null ? '—' : '${value.toStringAsFixed(2)} ms';

  /// 保留 [digits] 位小数的数值；`null` → 「不可用」。
  static String _decimalOrUnavailable(double? value, int digits) =>
      value == null || !value.isFinite
          ? '不可用'
          : value.toStringAsFixed(digits);

  /// 整数文本；`null` → 「不可用」。
  static String _intOrUnavailable(int? value) =>
      value == null ? '不可用' : '$value';

  /// 毫秒文本（2 位小数）；`null` → 「不可用」。
  static String _msOrUnavailable(double? value) =>
      value == null || !value.isFinite
          ? '不可用'
          : '${value.toStringAsFixed(2)} ms';

  /// mAh 文本（2 位小数）；`null` → 「不可用」。
  static String _mahOrUnavailable(double? value) =>
      value == null || !value.isFinite
          ? '不可用'
          : '${value.toStringAsFixed(2)} mAh';

  /// 唤醒锁时长人类可读；`null` → 「不可用」。
  static String _wakeOrUnavailable(int? ms) =>
      ms == null ? '不可用' : _durationText(ms);

  /// 毫秒 → 人类可读时长（`ms` / `s` / `min` / `h`）。
  static String _durationText(int ms) {
    if (ms < 1000) return '$ms ms';
    final double totalSec = ms / 1000.0;
    if (totalSec < 60) return '${totalSec.toStringAsFixed(1)} s';
    final double totalMin = totalSec / 60.0;
    if (totalMin < 60) {
      final int m = totalMin.floor();
      final int s = (totalSec - m * 60).round();
      return s == 0 ? '$m min' : '$m min $s s';
    }
    final int h = (totalMin / 60).floor();
    final int m = (totalMin - h * 60).round();
    return m == 0 ? '$h h' : '$h h $m min';
  }

  Widget _metric(
    BuildContext context,
    String label,
    String value, {
    String? sub,
  }) {
    final theme = Theme.of(context);
    return SizedBox(
      width: AppSpacing.massive * 2,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            value,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: AppTypography.weightSemiBold,
            ),
          ),
          if (sub != null)
            Text(
              sub,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
    );
  }
}

/// 可搜索的应用选择弹层（经 [AppSheet.showCustom] 呈现的 [AppSheetScaffold]）。
class _AppPickerSheet extends StatefulWidget {
  const _AppPickerSheet({required this.apps});

  final List<AppTarget> apps;

  @override
  State<_AppPickerSheet> createState() => _AppPickerSheetState();
}

class _AppPickerSheetState extends State<_AppPickerSheet> {
  String _keyword = '';

  List<AppTarget> get _filtered {
    if (_keyword.isEmpty) return widget.apps;
    final kw = _keyword.toLowerCase();
    return widget.apps
        .where(
          (app) =>
              app.label.toLowerCase().contains(kw) ||
              app.package.toLowerCase().contains(kw),
        )
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final apps = _filtered;
    return AppSheetScaffold(
      title: '选择应用',
      subtitle: '共 ${widget.apps.length} 个已安装应用',
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            autofocus: false,
            onChanged: (value) => setState(() => _keyword = value),
            decoration: const InputDecoration(
              hintText: '搜索应用名或包名…',
              prefixIcon: Icon(TablerIcons.search),
              isDense: true,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          if (widget.apps.isEmpty)
            Padding(
              padding: AppSpacing.allLG,
              child: Text(
                '未找到已安装应用',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            )
          else
            // 弹层骨架用 DecoratedBox 承载背景色，ListTile 需要就近的 Material
            // 才能正常绘制水波纹（否则框架会告警「ink splashes may be invisible」）。
            Material(
              type: MaterialType.transparency,
              child: ListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: apps.length,
                itemBuilder: (context, index) {
                  final app = apps[index];
                  return ListTile(
                    dense: true,
                    leading: Icon(
                      app.isSystem
                          ? TablerIcons.brand_android
                          : TablerIcons.apps,
                      size: AppTypography.iconMD,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    title: Text(
                      app.label,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyLarge,
                    ),
                    subtitle: Text(
                      app.package,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    onTap: () => Navigator.of(context).pop<AppTarget>(app),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

/// 阈值编辑弹层（统一底部弹层骨架 [AppSheetScaffold]）。
///
/// 保存时 `pop` 数值，取消 / 遮罩关闭 `pop(null)`；非法输入就地提示（走
/// [AppDialogs]，绝不抛错）。
class _PerfThresholdSheet extends StatefulWidget {
  const _PerfThresholdSheet({
    required this.title,
    required this.initial,
    required this.unit,
    required this.hint,
  });

  /// 弹层标题（如「CPU 占用阈值」）。
  final String title;

  /// 初始值。
  final double initial;

  /// 单位后缀（`%` / `°C` / `fps`）。
  final String unit;

  /// 副标题说明。
  final String hint;

  @override
  State<_PerfThresholdSheet> createState() => _PerfThresholdSheetState();
}

class _PerfThresholdSheetState extends State<_PerfThresholdSheet> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: _format(widget.initial));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  static String _format(double value) {
    if (!value.isFinite) return '';
    if (value == value.roundToDouble()) return value.toStringAsFixed(0);
    return value.toStringAsFixed(1);
  }

  void _submit() {
    final value = double.tryParse(_controller.text.trim());
    if (value == null || !value.isFinite) {
      AppDialogs.showError('请输入有效数字');
      return;
    }
    Navigator.of(context).pop<double>(value);
  }

  @override
  Widget build(BuildContext context) {
    return AppSheetScaffold(
      title: widget.title,
      subtitle: widget.hint,
      content: TextField(
        key: const Key('perf_alert_threshold_input'),
        controller: _controller,
        autofocus: true,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _submit(),
        decoration: InputDecoration(
          suffixText: widget.unit,
          isDense: true,
        ),
      ),
      actions: [
        TextButton(
          key: const Key('perf_alert_threshold_cancel'),
          onPressed: () => Navigator.of(context).pop<double>(null),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('perf_alert_threshold_save'),
          onPressed: _submit,
          child: const Text('保存'),
        ),
      ],
    );
  }
}
