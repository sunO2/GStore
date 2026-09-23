import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'package:gstore/core/design/app_components.dart';
import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/design/app_radius.dart';
import 'package:gstore/core/design/app_spacing.dart';
import 'package:gstore/core/design/app_typography.dart';
import 'package:gstore/core/rust/proxy/ProxyContract.dart';
import 'package:gstore/core/rust/proxy/ProxyModule.dart';
import 'package:gstore/core/utils/unit.dart';

import 'proxy_requests_facade.dart';

/// 单次 `requests.get` 拉取上限（拉取为准；本页不做无限分页）。
const int _pageLimit = 200;

/// 分组视图（Top 应用 / 域名 / IP、出站 / 规则分布）展示条数。
const int _groupLimit = 5;

/// 时间线趋势的桶数量与桶宽（按分钟聚合）。
const int _trendBucketCount = 24;
const int _trendBucketMs = 60 * 1000;

/// 单次渲染请求行上限，避免超长列表一次性 build（取最新 N 条）。
const int _maxRendered = 500;

/// 实时兜底轮询周期（脏信号为主、此定时器仅兜底）。
const Duration _fallbackInterval = Duration(seconds: 2);

/// 时间范围选项（`sinceMs` 由当前时间回推）。
class _RangeOption {
  const _RangeOption(this.label, this.rangeMs);

  final String label;
  final int rangeMs;
}

const List<_RangeOption> _rangeOptions = <_RangeOption>[
  _RangeOption('全部', 0),
  _RangeOption('5 分钟', 5 * 60 * 1000),
  _RangeOption('1 小时', 60 * 60 * 1000),
  _RangeOption('24 小时', 24 * 60 * 60 * 1000),
];

/// 网络类型筛选项（`null` = 全部）。
const List<String?> _networkOptions = <String?>[null, 'tcp', 'udp'];

/// 导出另存的测试接缝：调用系统保存对话框并返回落地路径（取消 → `null`）。
///
/// 生产默认走 [FilePicker.platform.saveFile]，测试注入假实现断言「保存被调用」。
typedef ProxyRequestsSaveFile = Future<String?> Function({
  required String fileName,
  required Uint8List bytes,
  required List<String> allowedExtensions,
});

/// 读取 Rust 侧已生成导出文件字节的测试接缝。
typedef ProxyRequestsReadFile = Future<Uint8List> Function(String path);

/// 一次导出的落地目标（Rust 产物路径 → 另存文件名 / 扩展名）。
class _ExportTarget {
  const _ExportTarget({
    required this.path,
    required this.fileName,
    required this.allowedExtensions,
  });

  final String path;
  final String fileName;
  final List<String> allowedExtensions;
}

/// 导出格式选项行（统一弹层内容；避免 [ListTile] 对 Material 祖先的依赖）。
class _ExportOption extends StatelessWidget {
  const _ExportOption({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: AppRadius.allMD,
      child: Padding(
        padding: AppSpacing.allMD,
        child: Row(
          children: [
            ColoredAliIcon(
              icon: icon,
              size: AppTypography.iconMD,
              color: scheme.primary,
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: theme.textTheme.bodyLarge),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    subtitle,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right,
              size: AppTypography.iconMD,
              color: scheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}

/// 实时「请求域名 / IP 收集」页（纯展示 / 触发层，Todo 15）。
///
/// * **概览卡**：总量、请求数、活跃数、`domainKnown:false` 占比（由当前拉取
///   窗口内的记录聚合展示，不在 Dart 落盘）。
/// * **实时请求列表**：域名、`dstIp:dstPort`、App（包名 / UID / 「未知应用」）、
///   入站 / 出站、字节、耗时、时间；点击经统一 [AppSheet] 详情弹层。
/// * **筛选**：应用 / 域名 / IP 子串、`network`、`outbound`、时间范围（本地过滤，
///   同时把后端支持的字段转发进 `requests.get.filter`）。
/// * **分组视图**：Top 应用 / Top 域名 / Top IP、时间线趋势、DNS 质量、
///   出站 / 规则分布（均由当前窗口记录在展示层聚合，**不落盘**）。
/// * **实时**：`proxy.request` 脏信号触发 `requestsGet`（**拉取为准**），
///   另有 2s `Timer` 兜底；页面不可见时暂停；[dispose] 清理定时器与订阅。
///
/// 门面与事件流均经构造函数注入，测试无需原生模块（[facade] 默认适配
/// [ProxyModule]，[events] 默认取 [ProxyModule.instance] 的事件流）。
class ProxyRequestsPage extends StatefulWidget {
  const ProxyRequestsPage({
    super.key,
    this.facade,
    this.events,
    this.initialLive = true,
    this.saveFile,
    this.readFile,
  });

  /// 收集页门面（测试可注入假实现；为空时用生产适配器）。
  final ProxyRequestsFacade? facade;

  /// 类型化代理事件流（测试可注入；为空时用 [ProxyModule.instance]）。
  final Stream<ProxyEvent>? events;

  /// 初始是否开启实时（脏信号 + 2s 兜底）。
  final bool initialLive;

  /// 导出另存接缝（测试注入；为空时走 [FilePicker.platform.saveFile]）。
  final ProxyRequestsSaveFile? saveFile;

  /// 导出文件读取接缝（测试注入；为空时读本地文件）。
  final ProxyRequestsReadFile? readFile;

  @override
  State<ProxyRequestsPage> createState() => _ProxyRequestsPageState();
}

class _ProxyRequestsPageState extends State<ProxyRequestsPage>
    with WidgetsBindingObserver {
  late final ProxyRequestsFacade _facade;
  late final Stream<ProxyEvent> _events;
  late final ProxyRequestsSaveFile _saveFile;
  late final ProxyRequestsReadFile _readFile;

  StreamSubscription<ProxyEvent>? _eventSub;
  Timer? _fallbackTimer;

  final TextEditingController _domainController = TextEditingController();
  final TextEditingController _ipController = TextEditingController();
  final TextEditingController _appController = TextEditingController();
  final TextEditingController _outboundController = TextEditingController();

  bool _live = true;
  bool _visible = true;
  bool _loading = true;
  bool _pullInFlight = false;
  bool _exporting = false;

  RequestPage? _page;
  String? _error;

  String _domainQuery = '';
  String _ipQuery = '';
  String _appQuery = '';
  String _outboundQuery = '';
  String? _network;
  int _rangeMs = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _facade = widget.facade ?? ProxyModuleRequestsFacade();
    _events = widget.events ?? ProxyModule.instance.events;
    _saveFile = widget.saveFile ?? _defaultSaveFile;
    _readFile = widget.readFile ?? _defaultReadFile;
    _live = widget.initialLive;
    _eventSub = _events.listen(_onEvent);
    if (_live) _startFallback();
    unawaited(_load());
  }

  @override
  void dispose() {
    _stopFallback();
    _eventSub?.cancel();
    _eventSub = null;
    WidgetsBinding.instance.removeObserver(this);
    _domainController.dispose();
    _ipController.dispose();
    _appController.dispose();
    _outboundController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 页面不可见（后台 / 暂停）时停表；恢复前台且实时开启时续上。
    final visible = state == AppLifecycleState.resumed;
    if (visible == _visible) return;
    _visible = visible;
    if (!_visible) {
      _stopFallback();
    } else if (_live) {
      _startFallback();
    }
  }

  // ==================== 实时 ====================

  /// 脏信号（`proxy.request`）→ 拉取（**拉取为准**）。
  ///
  /// 实时关闭或页面不可见时忽略；[dispose] 取消订阅。
  void _onEvent(ProxyEvent event) {
    if (!mounted || !_visible || !_live) return;
    if (event is ProxyRequestEvent) {
      unawaited(_fetch(silent: true));
    }
  }

  void _startFallback() {
    _fallbackTimer?.cancel();
    _fallbackTimer = Timer.periodic(
      _fallbackInterval,
      (_) => unawaited(_fetch(silent: true)),
    );
  }

  void _stopFallback() {
    _fallbackTimer?.cancel();
    _fallbackTimer = null;
  }

  void _toggleLive() {
    setState(() => _live = !_live);
    if (_live) {
      _startFallback();
      unawaited(_fetch(silent: true));
    } else {
      _stopFallback();
    }
  }

  // ==================== 加载 ====================

  /// 手动 / 首屏加载：整页 loading。
  Future<void> _load() async {
    await _fetch(silent: false);
  }

  /// 拉取 `requests.get`。
  ///
  /// [silent] 为 true（实时刷新 / 兜底轮询）时不切整页 loading、失败保留现有数据。
  Future<void> _fetch({bool silent = false}) async {
    if (_pullInFlight) return;
    _pullInFlight = true;
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final page = await _facade.requestsGet(_buildRequest());
      if (!mounted) return;
      setState(() {
        _page = page;
        _loading = false;
        _error = null;
      });
    } on ProxyModuleException catch (error) {
      if (!mounted || silent) return;
      setState(() {
        _error = error.message;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || silent) return;
      setState(() {
        _error = '请求列表加载失败：$error';
        _loading = false;
      });
    } finally {
      _pullInFlight = false;
    }
  }

  RequestGetRequest _buildRequest() {
    final filter = _buildFilter();
    return RequestGetRequest(
      limit: _pageLimit,
      filter: filter,
    );
  }

  RequestsFilter? _buildFilter() {
    final sinceMs = _rangeMs > 0
        ? DateTime.now().millisecondsSinceEpoch - _rangeMs
        : null;
    if (_domainQuery.isEmpty &&
        _network == null &&
        _outboundQuery.isEmpty &&
        sinceMs == null) {
      return null;
    }
    return RequestsFilter(
      domain: _domainQuery.isEmpty ? null : _domainQuery,
      network: _network,
      outbound: _outboundQuery.isEmpty ? null : _outboundQuery,
      sinceMs: sinceMs,
    );
  }

  Future<void> _confirmReset() async {
    final ok = await AppDialogs.showConfirmSheet(
      title: '清空请求记录',
      message: '将清空全部已采集的请求记录，且无法撤销。确定继续吗？',
      confirmText: '清空',
      isDangerous: true,
      icon: const Icon(Icons.delete_outline),
    );
    if (ok != true || !mounted) return;
    try {
      await _facade.requestsReset();
      if (!mounted) return;
      AppDialogs.showSuccess('已清空请求记录');
      await _load();
    } on ProxyModuleException catch (error) {
      if (!mounted) return;
      AppDialogs.showError(error.message, title: '清空失败');
    } catch (error) {
      if (!mounted) return;
      AppDialogs.showError('清空失败：$error');
    }
  }

  // ==================== 导出 ====================

  /// 「导出」入口：统一 [AppSheet] 选择 CSV / JSON / 两者。
  ///
  /// 选择后调用 `requests.export` 拿到 Rust 侧生成的文件路径与字节，再经
  /// [ProxyRequestsSaveFile] 另存。用户取消（弹层返回 `null` 或 `saveFile`
  /// 返回 `null`）**不报错、不提示失败**；成功提示包含行数；失败走
  /// [AppDialogs.showError] 且不崩溃。
  Future<void> _export() async {
    if (_exporting) return;
    final format = await AppDialogs.showContentSheet<String>(
      title: '导出请求记录',
      icon: const Icon(Icons.file_download_outlined),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _ExportOption(
            key: const Key('requests_export_csv'),
            icon: Icons.description_outlined,
            title: 'CSV',
            subtitle: '适合电子表格 / 数据分析',
            onTap: () => AppDialogs.popSheet<String>('csv'),
          ),
          _ExportOption(
            key: const Key('requests_export_json'),
            icon: Icons.data_object_outlined,
            title: 'JSON',
            subtitle: '适合程序化处理',
            onTap: () => AppDialogs.popSheet<String>('json'),
          ),
          _ExportOption(
            key: const Key('requests_export_both'),
            icon: Icons.file_copy_outlined,
            title: 'CSV + JSON',
            subtitle: '同时导出两种格式',
            onTap: () => AppDialogs.popSheet<String>('both'),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => AppDialogs.popSheet<String>(null),
          child: const Text('取消'),
        ),
      ],
    );
    if (format == null || !mounted) return;
    await _runExport(format);
  }

  /// 执行导出：`requestsExport` → 读字节 → 另存。
  Future<void> _runExport(String format) async {
    setState(() => _exporting = true);
    RequestExportResult result;
    try {
      result = await _facade.requestsExport(
        RequestExportRequest(format: format, filter: _buildFilter()),
      );
    } on ProxyModuleException catch (error) {
      if (!mounted) return;
      setState(() => _exporting = false);
      AppDialogs.showError(error.message, title: '导出失败');
      return;
    } catch (error) {
      if (!mounted) return;
      setState(() => _exporting = false);
      AppDialogs.showError('导出失败：$error', title: '导出失败');
      return;
    }
    if (!mounted) return;

    final timestamp = _exportTimestamp();
    final targets = <_ExportTarget>[
      if (result.csvPath != null && result.csvPath!.isNotEmpty)
        _ExportTarget(
          path: result.csvPath!,
          fileName: 'gstore_requests_$timestamp.csv',
          allowedExtensions: const <String>['csv'],
        ),
      if (result.jsonPath != null && result.jsonPath!.isNotEmpty)
        _ExportTarget(
          path: result.jsonPath!,
          fileName: 'gstore_requests_$timestamp.json',
          allowedExtensions: const <String>['json'],
        ),
    ];
    if (targets.isEmpty) {
      setState(() => _exporting = false);
      AppDialogs.showError('未生成可导出的文件', title: '导出失败');
      return;
    }

    try {
      var saved = 0;
      for (final target in targets) {
        final bytes = await _readFile(target.path);
        final outputPath = await _saveFile(
          fileName: target.fileName,
          bytes: bytes,
          allowedExtensions: target.allowedExtensions,
        );
        // 取消（返回 null / 空路径）：静默停止，不报错、不提示失败。
        if (outputPath == null || outputPath.isEmpty) {
          if (mounted) setState(() => _exporting = false);
          return;
        }
        saved++;
      }
      if (!mounted) return;
      setState(() => _exporting = false);
      final suffix = saved > 1 ? '（CSV + JSON）' : '';
      AppDialogs.showSuccess(
        '已导出 ${result.rows} 条请求记录$suffix',
        title: '导出成功',
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _exporting = false);
      AppDialogs.showError('导出失败：$error', title: '导出失败');
    }
  }

  /// 生产默认另存：系统保存对话框（与日志 / 备份导出同机制）。
  static Future<String?> _defaultSaveFile({
    required String fileName,
    required Uint8List bytes,
    required List<String> allowedExtensions,
  }) {
    return FilePicker.platform.saveFile(
      dialogTitle: '保存请求记录',
      fileName: fileName,
      lockParentWindow: true,
      type: FileType.custom,
      allowedExtensions: allowedExtensions,
      bytes: bytes,
    );
  }

  /// 生产默认读取：读 Rust 侧生成的导出文件字节。
  static Future<Uint8List> _defaultReadFile(String path) =>
      File(path).readAsBytes();

  /// 导出文件名时间戳（`yyyyMMdd_HHmmss`）。
  String _exportTimestamp() {
    final now = DateTime.now();
    return '${now.year}${_two(now.month)}${_two(now.day)}_'
        '${_two(now.hour)}${_two(now.minute)}${_two(now.second)}';
  }

  // ==================== 过滤（展示层，本地为准） ====================

  void _applyLocalFilter() => setState(() {});

  void _setNetwork(String? network) {
    if (_network == network) return;
    setState(() => _network = network);
  }

  void _setRange(_RangeOption option) {
    if (_rangeMs == option.rangeMs) return;
    setState(() => _rangeMs = option.rangeMs);
  }

  int _nowMs() => DateTime.now().millisecondsSinceEpoch;

  /// 当前窗口记录经本地筛选后的结果（同时转发后端支持的过滤字段）。
  List<RequestRecord> get _filteredRecords {
    final all = _page?.records ?? const <RequestRecord>[];
    final nowMs = _nowMs();
    final matched = all.where((record) {
      if (_network != null && record.network != _network) return false;
      if (_domainQuery.isNotEmpty &&
          !record.domain.toLowerCase().contains(_domainQuery)) {
        return false;
      }
      if (_ipQuery.isNotEmpty &&
          !record.dstIp.toLowerCase().contains(_ipQuery)) {
        return false;
      }
      if (_appQuery.isNotEmpty) {
        final haystack =
            '${record.packages.join(' ')} ${record.uid ?? ''}'.toLowerCase();
        if (!haystack.contains(_appQuery)) return false;
      }
      if (_outboundQuery.isNotEmpty &&
          !record.outbound.toLowerCase().contains(_outboundQuery)) {
        return false;
      }
      if (_rangeMs > 0 &&
          record.openTsMs > 0 &&
          record.openTsMs < nowMs - _rangeMs) {
        return false;
      }
      return true;
    }).toList();
    return matched.length <= _maxRendered
        ? matched
        : matched.sublist(0, _maxRendered);
  }

  // ==================== 渲染 ====================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('请求域名 / IP'),
        actions: [
          IconButton(
            key: const Key('requests_export'),
            tooltip: '导出',
            icon: const Icon(Icons.file_download_outlined),
            onPressed: _exporting ? null : _export,
          ),
          IconButton(
            key: const Key('requests_refresh'),
            tooltip: '刷新',
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : () => _load(),
          ),
          IconButton(
            key: const Key('requests_reset'),
            tooltip: '清空记录',
            icon: const Icon(Icons.delete_outline),
            onPressed: _page == null ? null : _confirmReset,
          ),
        ],
      ),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading && _page == null) {
      return const Center(child: AppLoading(size: AppLoadingSize.medium));
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverToBoxAdapter(child: _buildOverview(context)),
          SliverToBoxAdapter(child: _buildFilters(context)),
          ..._buildContentSlivers(context),
        ],
      ),
    );
  }

  List<Widget> _buildContentSlivers(BuildContext context) {
    final error = _error;
    if (error != null) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: _EmptyState(
            icon: Icons.error_outline,
            title: '请求列表不可用',
            message: error,
            actionLabel: '重试',
            onAction: _load,
          ),
        ),
      ];
    }
    final records = _filteredRecords;
    if (records.isEmpty) {
      final hasAny = (_page?.records ?? const <RequestRecord>[]).isNotEmpty;
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: _EmptyState(
            icon: hasAny
                ? Icons.filter_alt_off_outlined
                : Icons.history_toggle_off_outlined,
            title: hasAny ? '无匹配请求' : '暂无请求记录',
            message: hasAny
                ? '当前筛选条件没有匹配的请求。'
                : '代理引擎尚未采集到请求。',
          ),
        ),
      ];
    }
    return [
      SliverToBoxAdapter(child: _buildGrouped(context, records)),
      SliverToBoxAdapter(child: _buildListHeader(context, records.length)),
      SliverPadding(
        padding: AppSpacing.onlyHorizontalLG,
        sliver: SliverList.builder(
          itemCount: records.length,
          itemBuilder: (context, index) => _RequestRowCard(
            key: ValueKey('request_row_${records[index].recordId}'),
            record: records[index],
            onTap: () => _showDetail(records[index]),
          ),
        ),
      ),
      const SliverToBoxAdapter(child: SizedBox(height: AppSpacing.xxl)),
    ];
  }

  /// 概览卡：总量、请求数、活跃、`domainKnown:false` 占比。
  Widget _buildOverview(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final page = _page;
    final records = page?.records ?? const <RequestRecord>[];
    final totalBytes = records.fold<int>(
      0,
      (sum, record) => sum + record.uploadBytes + record.downloadBytes,
    );
    final active = records
        .where((record) => record.closeReason == 'open')
        .length;
    final unknownDomains =
        records.where((record) => !record.domainKnown).length;
    final unknownRatio = records.isEmpty
        ? 0
        : ((unknownDomains / records.length) * 100).round();

    return Padding(
      padding: const EdgeInsets.only(
        left: AppSpacing.lg,
        right: AppSpacing.lg,
        top: AppSpacing.lg,
      ),
      child: Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: AppSpacing.allMD,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  ColoredAliIcon(
                    icon: Icons.swap_vert,
                    size: AppTypography.iconMD,
                    color: scheme.primary,
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Text('采集概览', style: theme.textTheme.titleSmall),
                  const Spacer(),
                  FilterChip(
                    key: const Key('requests_live_toggle'),
                    label: const Text('实时'),
                    selected: _live,
                    onSelected: (_) => _toggleLive(),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              if (page == null)
                const Padding(
                  padding: AppSpacing.topBottomSM,
                  child: Center(child: AppLoading(size: AppLoadingSize.small)),
                )
              else ...[
                Wrap(
                  spacing: AppSpacing.xl,
                  runSpacing: AppSpacing.md,
                  children: [
                    _OverviewMetric(
                      icon: Icons.arrow_upward,
                      label: '总量',
                      value: byteSize(totalBytes),
                    ),
                    _OverviewMetric(
                      icon: Icons.swap_vert,
                      label: '请求数',
                      value: '${records.length}',
                    ),
                    _OverviewMetric(
                      icon: Icons.bolt,
                      label: '活跃',
                      value: '$active',
                    ),
                    _OverviewMetric(
                      icon: Icons.dns_outlined,
                      label: '未知域名',
                      value: '$unknownRatio%',
                      sub: '$unknownDomains / ${records.length}',
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.sm),
                Text(
                  '保留 ${page.retained}/${page.capacity} · '
                  '淘汰 ${page.evicted} · 丢弃 ${page.dropped}',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// 筛选区：应用 / 域名 / IP 子串、network、outbound、时间范围。
  Widget _buildFilters(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: AppSpacing.allLG,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: const Key('requests_app_filter'),
            controller: _appController,
            onChanged: (value) {
              _appQuery = value.trim().toLowerCase();
              _applyLocalFilter();
            },
            decoration: const InputDecoration(
              isDense: true,
              labelText: '应用',
              hintText: '包名 / UID 子串',
              prefixIcon: Icon(Icons.apps),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          TextField(
            key: const Key('requests_domain_filter'),
            controller: _domainController,
            onChanged: (value) {
              _domainQuery = value.trim().toLowerCase();
              _applyLocalFilter();
            },
            decoration: const InputDecoration(
              isDense: true,
              labelText: '域名',
              hintText: '域名子串',
              prefixIcon: Icon(Icons.dns_outlined),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: const Key('requests_ip_filter'),
                  controller: _ipController,
                  onChanged: (value) {
                    _ipQuery = value.trim().toLowerCase();
                    _applyLocalFilter();
                  },
                  decoration: const InputDecoration(
                    isDense: true,
                    labelText: 'IP',
                    hintText: '目标 IP 子串',
                    prefixIcon: Icon(Icons.lan_outlined),
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: TextField(
                  key: const Key('requests_outbound_filter'),
                  controller: _outboundController,
                  onChanged: (value) {
                    _outboundQuery = value.trim().toLowerCase();
                    _applyLocalFilter();
                  },
                  decoration: const InputDecoration(
                    isDense: true,
                    labelText: '出站',
                    hintText: '出站子串',
                    prefixIcon: Icon(Icons.alt_route),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            '网络',
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          Wrap(
            spacing: AppSpacing.xs,
            runSpacing: AppSpacing.xs,
            children: [
              for (final option in _networkOptions)
                ChoiceChip(
                  key: Key('requests_network_${option ?? 'all'}'),
                  label: Text(option ?? '全部'),
                  selected: _network == option,
                  onSelected: (_) => _setNetwork(option),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            '时间范围',
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          Wrap(
            spacing: AppSpacing.xs,
            runSpacing: AppSpacing.xs,
            children: [
              for (final option in _rangeOptions)
                ChoiceChip(
                  key: Key('requests_range_${option.rangeMs}'),
                  label: Text(option.label),
                  selected: _rangeMs == option.rangeMs,
                  onSelected: (_) => _setRange(option),
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// 分组视图：Top 应用 / 域名 / IP、时间线趋势、DNS 质量、出站 / 规则分布。
  Widget _buildGrouped(BuildContext context, List<RequestRecord> records) {
    final topApps = _groupTop(records, _appLabel);
    final topDomains = _groupTop(
      records,
      (record) => record.domain.isEmpty ? '(未知域名)' : record.domain,
    );
    final topIps = _groupTop(
      records,
      (record) => record.dstIp.isEmpty ? '(未知 IP)' : record.dstIp,
    );
    final outbound = _groupTop(
      records,
      (record) => record.outbound.isEmpty ? '未匹配' : record.outbound,
    );
    final rules = _groupTop(
      records,
      (record) => record.rule.isEmpty ? '未匹配规则' : record.rule,
    );
    final known =
        records.where((record) => record.domainKnown).length;
    return Padding(
      padding: AppSpacing.onlyHorizontalLG,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _GroupCard(
            key: const Key('requests_group_apps'),
            title: 'Top 应用',
            icon: Icons.apps,
            rows: topApps,
          ),
          _GroupCard(
            key: const Key('requests_group_domains'),
            title: 'Top 域名',
            icon: Icons.dns_outlined,
            rows: topDomains,
          ),
          _GroupCard(
            key: const Key('requests_group_ips'),
            title: 'Top IP',
            icon: Icons.lan_outlined,
            rows: topIps,
          ),
          _TrendCard(
            key: const Key('requests_group_trend'),
            counts: _trendBuckets(records),
          ),
          _DnsQualityCard(
            key: const Key('requests_group_dns'),
            known: known,
            total: records.length,
          ),
          _GroupCard(
            key: const Key('requests_group_outbound'),
            title: '出站分布',
            icon: Icons.alt_route,
            rows: outbound,
          ),
          _GroupCard(
            key: const Key('requests_group_rules'),
            title: '规则分布',
            icon: Icons.rule,
            rows: rules,
          ),
        ],
      ),
    );
  }

  Widget _buildListHeader(BuildContext context, int count) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.md,
        AppSpacing.lg,
        AppSpacing.xs,
      ),
      child: Row(
        children: [
          ColoredAliIcon(
            icon: Icons.history,
            size: AppTypography.iconLG,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text('实时请求', style: theme.textTheme.titleSmall),
          ),
          Text(
            '$count',
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showDetail(RequestRecord record) async {
    await AppDialogs.showContentSheet<void>(
      title: record.domain.isEmpty ? '请求详情' : record.domain,
      subtitle: _formatDateTime(record.openTsMs),
      icon: const Icon(Icons.swap_vert),
      content: _RequestDetail(record: record),
      actions: [
        TextButton(
          onPressed: () => AppDialogs.popSheet<void>(null),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}

/// App 归属展示：包名优先，其次 UID，`uid == null` 显式「未知应用」。
String _appLabel(RequestRecord record) {
  if (record.uid == null) return '未知应用';
  if (record.packages.isNotEmpty) return record.packages.first;
  return 'UID ${record.uid}';
}

/// 分组统计行（标签 + 计数 + 字节）。
class _GroupRow {
  const _GroupRow({
    required this.label,
    required this.count,
    required this.bytes,
  });

  final String label;
  final int count;
  final int bytes;
}

/// 按 [keyOf] 聚合为 Top [limit] 行（计数降序，字节次序）。
List<_GroupRow> _groupTop(
  List<RequestRecord> records,
  String Function(RequestRecord record) keyOf, {
  int limit = _groupLimit,
}) {
  final counts = <String, int>{};
  final bytes = <String, int>{};
  for (final record in records) {
    final key = keyOf(record);
    counts[key] = (counts[key] ?? 0) + 1;
    bytes[key] =
        (bytes[key] ?? 0) + record.uploadBytes + record.downloadBytes;
  }
  final rows = counts.keys
      .map((key) => _GroupRow(
            label: key,
            count: counts[key]!,
            bytes: bytes[key]!,
          ))
      .toList()
    ..sort((a, b) {
      final byCount = b.count.compareTo(a.count);
      return byCount != 0 ? byCount : b.bytes.compareTo(a.bytes);
    });
  return rows.take(limit).toList();
}

/// 时间线趋势：按分钟分桶计数，取最近 [_trendBucketCount] 个桶。
List<int> _trendBuckets(List<RequestRecord> records) {
  final buckets = <int, int>{};
  for (final record in records) {
    if (record.openTsMs <= 0) continue;
    final bucket = record.openTsMs ~/ _trendBucketMs;
    buckets[bucket] = (buckets[bucket] ?? 0) + 1;
  }
  if (buckets.isEmpty) return const <int>[];
  final keys = buckets.keys.toList()..sort();
  final recent = keys.length <= _trendBucketCount
      ? keys
      : keys.sublist(keys.length - _trendBucketCount);
  return recent.map((key) => buckets[key]!).toList();
}

/// 总览指标（图标 + 标签 + 值 + 可选副值）。
class _OverviewMetric extends StatelessWidget {
  const _OverviewMetric({
    required this.icon,
    required this.label,
    required this.value,
    this.sub,
  });

  final IconData icon;
  final String label;
  final String value;
  final String? sub;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: AppTypography.iconXS, color: scheme.primary),
            const SizedBox(width: AppSpacing.xs),
            Text(
              label,
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(value, style: theme.textTheme.titleSmall),
        if (sub != null)
          Text(
            sub!,
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
      ],
    );
  }
}

/// 通用分组卡（Top 列表：标签 + 计数 + 字节）。
class _GroupCard extends StatelessWidget {
  const _GroupCard({
    super.key,
    required this.title,
    required this.icon,
    required this.rows,
  });

  final String title;
  final IconData icon;
  final List<_GroupRow> rows;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: AppSpacing.onlyVerticalXS,
      child: Padding(
        padding: AppSpacing.allMD,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                ColoredAliIcon(
                  icon: icon,
                  size: AppTypography.iconSM,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: AppSpacing.sm),
                Text(title, style: theme.textTheme.titleSmall),
              ],
            ),
            const SizedBox(height: AppSpacing.xs),
            if (rows.isEmpty)
              Text(
                '暂无数据',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              )
            else
              for (final row in rows) _GroupRowTile(row: row),
          ],
        ),
      ),
    );
  }
}

class _GroupRowTile extends StatelessWidget {
  const _GroupRowTile({required this.row});

  final _GroupRow row;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: AppSpacing.onlyVerticalXS,
      child: Row(
        children: [
          Expanded(
            child: Text(
              row.label,
              style: theme.textTheme.bodySmall,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Text(
            '${row.count} · ${byteSize(row.bytes)}',
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// 时间线趋势卡（自绘等高柱状，纯展示）。
class _TrendCard extends StatelessWidget {
  const _TrendCard({super.key, required this.counts});

  final List<int> counts;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final maxCount = counts.isEmpty
        ? 0
        : counts.reduce((a, b) => a > b ? a : b);
    return Card(
      margin: AppSpacing.onlyVerticalXS,
      child: Padding(
        padding: AppSpacing.allMD,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                ColoredAliIcon(
                  icon: Icons.show_chart,
                  size: AppTypography.iconSM,
                  color: scheme.primary,
                ),
                const SizedBox(width: AppSpacing.sm),
                Text('时间线趋势', style: theme.textTheme.titleSmall),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            if (counts.isEmpty)
              Text(
                '暂无数据',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              )
            else
              SizedBox(
                height: AppSpacing.huge,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    for (final count in counts)
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 1,
                          ),
                          child: FractionallySizedBox(
                            alignment: Alignment.bottomCenter,
                            heightFactor: maxCount == 0
                                ? 0.0
                                : (count / maxCount).clamp(0.02, 1.0).toDouble(),
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: scheme.primary,
                                borderRadius: AppRadius.allXS,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// DNS 质量卡（`domainKnown` 命中率）。
class _DnsQualityCard extends StatelessWidget {
  const _DnsQualityCard({
    super.key,
    required this.known,
    required this.total,
  });

  final int known;
  final int total;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final unknown = total - known;
    final ratio = total == 0 ? 0 : ((known / total) * 100).round();
    return Card(
      margin: AppSpacing.onlyVerticalXS,
      child: Padding(
        padding: AppSpacing.allMD,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                ColoredAliIcon(
                  icon: Icons.verified_outlined,
                  size: AppTypography.iconSM,
                  color: scheme.primary,
                ),
                const SizedBox(width: AppSpacing.sm),
                Text('DNS 质量', style: theme.textTheme.titleSmall),
              ],
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              '域名可解析 $ratio% · 已解析 $known · 未知 $unknown / 共 $total',
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

/// 实时请求行卡片（长域名 / IP 一律省略号，不溢出）。
class _RequestRowCard extends StatelessWidget {
  const _RequestRowCard({
    super.key,
    required this.record,
    required this.onTap,
  });

  final RequestRecord record;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final title = record.domain.isEmpty ? record.dstIp : record.domain;
    final endpoint = '${record.dstIp}:${record.dstPort}';
    final strategy = <String>[
      record.network.isEmpty ? '未知' : record.network,
      if (record.outbound.isNotEmpty) record.outbound,
    ].join(' · ');
    return Card(
      margin: AppSpacing.onlyVerticalXS,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: AppSpacing.allMD,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            title.isEmpty ? '(未知)' : title,
                            style: theme.textTheme.bodyMedium,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (!record.domainKnown) ...[
                          const SizedBox(width: AppSpacing.xs),
                          Container(
                            padding: AppSpacing.horizontalSM_verticalXS,
                            decoration: BoxDecoration(
                              color: scheme.surfaceContainerHighest,
                              borderRadius: AppRadius.allMD,
                            ),
                            child: Text(
                              '未知',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      endpoint,
                      style: AppTypography.code.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      '${_appLabel(record)} · $strategy',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (record.src.isNotEmpty) ...[
                      const SizedBox(height: AppSpacing.xs),
                      Text(
                        '入站 ${record.src}',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    byteSize(record.uploadBytes + record.downloadBytes),
                    style: theme.textTheme.titleSmall,
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    record.durationMs == null
                        ? '进行中'
                        : '${record.durationMs} ms',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    _formatTime(record.openTsMs),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 请求详情（统一弹层内容，完整字段）。
class _RequestDetail extends StatelessWidget {
  const _RequestDetail({required this.record});

  final RequestRecord record;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _DetailField(label: '记录 ID', value: '${record.recordId}'),
        _DetailField(label: '连接 ID', value: record.connId),
        _DetailField(label: '域名', value: record.domain),
        _DetailField(
          label: '域名状态',
          value: record.domainKnown ? '已解析' : '未知（显示目标 IP）',
        ),
        _DetailField(label: '目标地址', value: '${record.dstIp}:${record.dstPort}'),
        _DetailField(label: '入站（源）', value: record.src),
        _DetailField(label: '网络', value: record.network),
        _DetailField(label: '应用', value: _appLabel(record)),
        _DetailField(label: 'UID', value: record.uid?.toString() ?? '—'),
        _DetailField(
          label: 'UID 状态',
          value: record.uidState.wire,
        ),
        if (record.packages.isNotEmpty)
          _DetailField(label: '包名', value: record.packages.join(', ')),
        _DetailField(label: '出站', value: record.outbound),
        _DetailField(label: '规则', value: record.rule),
        _DetailField(label: '规则载荷', value: record.rulePayload),
        _DetailField(label: '上传', value: byteSize(record.uploadBytes)),
        _DetailField(label: '下载', value: byteSize(record.downloadBytes)),
        _DetailField(
          label: '总计',
          value: byteSize(record.uploadBytes + record.downloadBytes),
        ),
        _DetailField(
          label: '耗时',
          value: record.durationMs == null ? '进行中' : '${record.durationMs} ms',
        ),
        _DetailField(label: '开始', value: _formatDateTime(record.openTsMs)),
        if (record.closeTsMs != null)
          _DetailField(label: '结束', value: _formatDateTime(record.closeTsMs!)),
        _DetailField(label: '结束原因', value: record.closeReason),
      ],
    );
  }
}

/// 详情字段：标签 + 值（值用等宽字体）。
class _DetailField extends StatelessWidget {
  const _DetailField({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final display = value.trim().isEmpty ? '—' : value;
    return Padding(
      padding: AppSpacing.onlyBottomMD,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            display,
            style: AppTypography.code.copyWith(
              color: theme.colorScheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Center(
      child: Padding(
        padding: AppSpacing.allXL,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ColoredAliIcon(
              icon: icon,
              size: AppTypography.iconXXXL,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(height: AppSpacing.md),
            Text(title, style: theme.textTheme.titleMedium),
            const SizedBox(height: AppSpacing.sm),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: AppSpacing.lg),
              FilledButton(onPressed: onAction, child: Text(actionLabel!)),
            ],
          ],
        ),
      ),
    );
  }
}

/// 两位补零。
String _two(int value) => value.toString().padLeft(2, '0');

/// 毫秒时间戳 → `HH:mm:ss`（0 = 空）。
String _formatTime(int tsMs) {
  if (tsMs <= 0) return '';
  final time = DateTime.fromMillisecondsSinceEpoch(tsMs).toLocal();
  return '${_two(time.hour)}:${_two(time.minute)}:${_two(time.second)}';
}

/// 毫秒时间戳 → `yyyy-MM-dd HH:mm:ss`（0 = 空）。
String _formatDateTime(int tsMs) {
  if (tsMs <= 0) return '';
  final time = DateTime.fromMillisecondsSinceEpoch(tsMs).toLocal();
  return '${time.year}-${_two(time.month)}-${_two(time.day)} '
      '${_two(time.hour)}:${_two(time.minute)}:${_two(time.second)}';
}
