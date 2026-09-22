import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:gstore/core/design/app_components.dart';
import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/design/app_spacing.dart';
import 'package:gstore/core/design/app_typography.dart';
import 'package:gstore/core/icons/Icons.dart';
import 'package:gstore/core/logger/LogManager.dart';
import 'package:gstore/core/rust/proxy/ProxyContract.dart';
import 'package:gstore/core/rust/proxy/ProxyModule.dart';
import 'package:gstore/core/utils/unit.dart';

import 'proxy_logs_facade.dart';

/// 结构化记录类别筛选（纯内存过滤，不新增后端调用）。
///
/// * [all]：模块消息 + 全部结构化记录（连接 / DNS / message）。
/// * [connection]：仅连接记录。
/// * [dns]：仅 DNS 记录。
/// * [message]：模块实时消息（[LogManager] 推送）+ 结构化 message 记录。
enum _KindFilter {
  all('全部'),
  connection('连接'),
  dns('DNS'),
  message('消息');

  const _KindFilter(this.label);

  final String label;
}

/// 代理日志查看器（纯展示 / 触发层）。
///
/// * **实时模块日志**：`LogManager` 推送流（模块经宿主 log 回调接入）。
/// * **结构化记录**：`log.get` 的连接 / DNS / message 结构化条目。
/// * 级别筛选经 `log.set_level` 生效；类别 / 搜索为内存过滤。
/// * 支持自动刷新（每 2s，可暂停）、手动刷新、复制当前列表与单条详情。
///
/// 门面与日志源均经构造函数注入，测试无需原生模块。
class ProxyLogsPage extends StatefulWidget {
  const ProxyLogsPage({super.key, this.facade, this.logSource});

  /// 代理模块门面（测试可注入假实现；为空时用生产适配器）。
  final ProxyLogsFacade? facade;

  /// 模块日志源（测试可注入；为空时用 [ManagerProxyLogSource]）。
  final ProxyLogSource? logSource;

  @override
  State<ProxyLogsPage> createState() => _ProxyLogsPageState();
}

class _ProxyLogsPageState extends State<ProxyLogsPage>
    with WidgetsBindingObserver {
  late final ProxyLogsFacade _facade;
  late final ProxyLogSource _logSource;

  final TextEditingController _searchController = TextEditingController();

  StreamSubscription<List<LogEntry>>? _logSub;
  Timer? _autoRefreshTimer;

  /// 单次渲染上限，避免超长列表一次性 build（取最新 N 条）。
  static const int _maxRendered = 1000;

  /// 自动刷新间隔。
  static const Duration _autoRefreshInterval = Duration(seconds: 2);

  ProxyLogLevel _level = ProxyLogLevel.info;
  _KindFilter _kindFilter = _KindFilter.all;
  String _query = '';
  bool _loading = true;
  bool _loadInFlight = false;
  bool _autoRefresh = false;
  String? _error;
  List<LogEntry> _liveLogs = const <LogEntry>[];
  List<LogRecord> _records = const <LogRecord>[];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _facade = widget.facade ?? ProxyModuleLogsFacade();
    _logSource = widget.logSource ?? const ManagerProxyLogSource();
    _liveLogs = List<LogEntry>.of(_logSource.logs);
    _logSub = _logSource.stream.listen((logs) {
      if (!mounted) return;
      setState(() => _liveLogs = List<LogEntry>.of(logs));
    });
    _load();
  }

  @override
  void dispose() {
    _autoRefreshTimer?.cancel();
    _autoRefreshTimer = null;
    WidgetsBinding.instance.removeObserver(this);
    _logSub?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 页面不可见（后台/暂停）时停表，恢复前台且自动刷新开启时续上。
    if (state == AppLifecycleState.resumed) {
      if (_autoRefresh) _startAutoRefresh();
    } else {
      _stopAutoRefresh();
    }
  }

  // ==================== 加载 / 刷新 ====================

  /// 拉取 `log.get` 结构化记录。
  ///
  /// [silent] 为 true 时（自动刷新）不显示整页 loading、失败时保留现有数据。
  Future<void> _load({bool silent = false}) async {
    if (_loadInFlight) return;
    _loadInFlight = true;
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final page = await _facade.logGet(
        LogGetRequest(level: _level.wire, limit: 500),
      );
      if (!mounted) return;
      setState(() {
        _records = page.records;
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
        _error = '日志加载失败：$error';
        _loading = false;
      });
    } finally {
      _loadInFlight = false;
    }
  }

  void _startAutoRefresh() {
    _autoRefreshTimer?.cancel();
    _autoRefreshTimer = Timer.periodic(
      _autoRefreshInterval,
      (_) => _load(silent: true),
    );
  }

  void _stopAutoRefresh() {
    _autoRefreshTimer?.cancel();
    _autoRefreshTimer = null;
  }

  void _setAutoRefresh(bool enabled) {
    if (_autoRefresh == enabled) return;
    setState(() => _autoRefresh = enabled);
    if (enabled) {
      _load(silent: true);
      _startAutoRefresh();
    } else {
      _stopAutoRefresh();
    }
  }

  Future<void> _setLevel(ProxyLogLevel level) async {
    setState(() => _level = level);
    try {
      await _facade.logSetLevel(level.wire);
    } on ProxyModuleException catch (error) {
      if (!mounted) return;
      AppDialogs.showError(error.message, title: '级别设置失败');
      return;
    } catch (error) {
      if (!mounted) return;
      AppDialogs.showError('级别设置失败：$error');
      return;
    }
    await _load();
  }

  // ==================== 过滤 ====================

  int _levelRank(ProxyLogLevel level) => switch (level) {
        ProxyLogLevel.debug => 0,
        ProxyLogLevel.info => 1,
        ProxyLogLevel.warn => 2,
        ProxyLogLevel.error => 3,
        ProxyLogLevel.unknown => -1,
      };

  int _logEntryRank(LogEntry entry) => switch (entry.level) {
        LogLevel.debug => 0,
        LogLevel.info => 1,
        LogLevel.warning => 2,
        LogLevel.error => 3,
        LogLevel.all => -1,
      };

  bool _matchesQuery(String haystack) {
    if (_query.isEmpty) return true;
    return haystack.toLowerCase().contains(_query);
  }

  /// 连接 / DNS 视图下不展示实时模块消息区块。
  bool get _showLiveSection =>
      _kindFilter == _KindFilter.all || _kindFilter == _KindFilter.message;

  bool _kindMatches(ProxyLogKind kind) => switch (_kindFilter) {
        _KindFilter.all => true,
        _KindFilter.connection => kind == ProxyLogKind.connection,
        _KindFilter.dns => kind == ProxyLogKind.dns,
        _KindFilter.message => kind == ProxyLogKind.message,
      };

  /// 截取最新 [max] 条，防止超长列表一次性 build。
  List<T> _cap<T>(List<T> items) => items.length <= _maxRendered
      ? items
      : items.sublist(items.length - _maxRendered);

  List<LogEntry> get _filteredLiveLogs {
    final minRank = _levelRank(_level);
    final matched = _liveLogs.where((entry) {
      if (_logEntryRank(entry) < minRank) return false;
      final data = entry.data?.toString() ?? '';
      return _matchesQuery('${entry.message} ${entry.level.label} $data');
    }).toList();
    return _cap(matched);
  }

  List<LogEntry> get _visibleLive =>
      _showLiveSection ? _filteredLiveLogs : const <LogEntry>[];

  List<LogRecord> get _filteredRecords {
    final minRank = _levelRank(_level);
    final matched = _records.where((record) {
      if (!_kindMatches(record.kind)) return false;
      if (_levelRank(record.level) < minRank) return false;
      final connection = record.connection;
      final dns = record.dns;
      return _matchesQuery([
        record.message,
        record.level.wire,
        record.kind.wire,
        if (connection != null) connection.domain,
        if (connection != null) connection.outbound,
        if (connection != null) connection.rule,
        if (connection != null) connection.rulePayload,
        if (connection != null) connection.dst,
        if (dns != null) dns.domain,
        if (dns != null) dns.qtype,
        if (dns != null) dns.rcode,
      ].join(' '));
    }).toList();
    return _cap(matched);
  }

  List<LogRecord> get _visibleRecords => _filteredRecords;

  // ==================== 复制 / 详情 ====================

  Future<void> _copy(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    AppDialogs.showSuccess('已复制到剪贴板');
  }

  void _copyAllVisible() {
    final lines = <String>[
      for (final entry in _visibleLive) entry.toFormattedString(),
      for (final record in _visibleRecords) _formatRecord(record),
    ];
    if (lines.isEmpty) {
      AppDialogs.showInfo('当前没有可复制的日志');
      return;
    }
    _copy(lines.join('\n'));
  }

  Future<void> _showRecordDetail(LogRecord record) async {
    final text = _formatRecord(record);
    await AppDialogs.showContentSheet<void>(
      title: '${record.kind.wire} 记录',
      subtitle: _formatDateTime(record.tsMs),
      icon: const Icon(Icons.article_outlined),
      content: _RecordDetailContent(record: record),
      actions: [
        TextButton(
          onPressed: () => AppDialogs.popSheet<void>(null),
          child: const Text('关闭'),
        ),
        FilledButton(
          onPressed: () {
            _copy(text);
            AppDialogs.popSheet<void>(null);
          },
          child: const Text('复制'),
        ),
      ],
    );
  }

  Future<void> _showLiveDetail(LogEntry entry) async {
    final text = entry.toFormattedString();
    await AppDialogs.showContentSheet<void>(
      title: '模块消息',
      subtitle: entry.dateTimeString,
      icon: const Icon(Icons.notes_outlined),
      content: _LiveDetailContent(entry: entry),
      actions: [
        TextButton(
          onPressed: () => AppDialogs.popSheet<void>(null),
          child: const Text('关闭'),
        ),
        FilledButton(
          onPressed: () {
            _copy(text);
            AppDialogs.popSheet<void>(null);
          },
          child: const Text('复制'),
        ),
      ],
    );
  }

  // ==================== 渲染 ====================

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('代理日志'),
        actions: [
          IconButton(
            key: const Key('log_autorefresh_toggle'),
            tooltip: _autoRefresh ? '暂停自动刷新' : '自动刷新',
            icon: Icon(_autoRefresh ? Icons.pause : Icons.play_arrow),
            color: _autoRefresh ? scheme.primary : null,
            onPressed: () => _setAutoRefresh(!_autoRefresh),
          ),
          IconButton(
            key: const Key('log_copy_all'),
            tooltip: '复制当前列表',
            icon: const Icon(Icons.copy_all),
            onPressed: _copyAllVisible,
          ),
          IconButton(
            key: const Key('log_refresh'),
            tooltip: '刷新',
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : () => _load(),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: AppSpacing.allLG,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SegmentedButton<ProxyLogLevel>(
                  key: const Key('log_level_selector'),
                  segments: const [
                    ButtonSegment(value: ProxyLogLevel.debug, label: Text('DEBUG')),
                    ButtonSegment(value: ProxyLogLevel.info, label: Text('INFO')),
                    ButtonSegment(value: ProxyLogLevel.warn, label: Text('WARN')),
                    ButtonSegment(value: ProxyLogLevel.error, label: Text('ERROR')),
                  ],
                  selected: {_level},
                  showSelectedIcon: false,
                  onSelectionChanged: (selection) => _setLevel(selection.first),
                ),
                const SizedBox(height: AppSpacing.md),
                SegmentedButton<_KindFilter>(
                  key: const Key('log_kind_selector'),
                  segments: [
                    for (final kind in _KindFilter.values)
                      ButtonSegment(value: kind, label: Text(kind.label)),
                  ],
                  selected: {_kindFilter},
                  showSelectedIcon: false,
                  onSelectionChanged: (selection) =>
                      setState(() => _kindFilter = selection.first),
                ),
                const SizedBox(height: AppSpacing.md),
                TextField(
                  key: const Key('log_search_field'),
                  controller: _searchController,
                  onChanged: (value) => setState(() => _query = value.trim()),
                  decoration: InputDecoration(
                    labelText: '搜索',
                    hintText: '域名 / 出站 / 规则 / 级别 / 内容',
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: _query.isEmpty
                        ? null
                        : IconButton(
                            key: const Key('log_search_clear'),
                            tooltip: '清除搜索',
                            icon: const Icon(Icons.clear),
                            onPressed: () {
                              _searchController.clear();
                              setState(() => _query = '');
                            },
                          ),
                  ),
                ),
                if (_autoRefresh)
                  Padding(
                    padding: AppSpacing.onlyTopSM,
                    child: Row(
                      key: const Key('log_autorefresh_indicator'),
                      children: [
                        Icon(
                          Icons.autorenew,
                          size: AppTypography.iconSM,
                          color: scheme.primary,
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        Expanded(
                          child: Text(
                            '自动刷新中（每 2 秒）',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          Expanded(child: _buildList(context)),
        ],
      ),
    );
  }

  String get _recordsSectionTitle => switch (_kindFilter) {
        _KindFilter.all => '结构化记录（连接 / DNS / 消息）',
        _KindFilter.connection => '连接记录',
        _KindFilter.dns => 'DNS 记录',
        _KindFilter.message => '结构化消息',
      };

  Widget _buildList(BuildContext context) {
    if (_loading) {
      return const Center(child: AppLoading(size: AppLoadingSize.medium));
    }
    final error = _error;
    if (error != null) {
      return _EmptyState(
        icon: Icons.error_outline,
        title: '日志不可用',
        message: error,
        actionLabel: '重试',
        onAction: () => _load(),
      );
    }

    final live = _visibleLive;
    final records = _visibleRecords;
    final hasAny = _liveLogs.isNotEmpty || _records.isNotEmpty;

    if (!hasAny) {
      return const _EmptyState(
        icon: Icons.history_toggle_off_outlined,
        title: '暂无日志',
        message: '代理引擎尚未产生日志。',
      );
    }
    if (live.isEmpty && records.isEmpty) {
      return const _EmptyState(
        icon: Icons.filter_alt_off_outlined,
        title: '无匹配日志',
        message: '当前级别、类别或搜索条件没有匹配的日志。',
      );
    }

    return ListView(
      padding: AppSpacing.onlyHorizontalLG,
      children: [
        if (live.isNotEmpty) ...[
          _SectionHeader(
            icon: AliIcon.history,
            title: '模块消息',
            trailing: '${live.length}',
          ),
          for (final entry in live)
            _LiveLogTile(
              key: ValueKey('live_log_${entry.timestamp.microsecondsSinceEpoch}'),
              entry: entry,
              onCopy: () => _copy(entry.toFormattedString()),
              onTap: () => _showLiveDetail(entry),
            ),
        ],
        if (records.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.sm),
          _SectionHeader(
            icon: Icons.storage,
            title: _recordsSectionTitle,
            trailing: '${records.length}',
          ),
          for (final record in records)
            _StructuredLogTile(
              key: ValueKey('structured_log_${record.cursor}'),
              record: record,
              onCopy: () => _copy(_formatRecord(record)),
              onTap: () => _showRecordDetail(record),
            ),
        ],
        const SizedBox(height: AppSpacing.xxl),
      ],
    );
  }

  String _formatRecord(LogRecord record) {
    final buffer = StringBuffer()
      ..write(
        '${_formatTime(record.tsMs)} [${record.level.wire}] ${record.kind.wire}',
      );
    final connection = record.connection;
    if (connection != null) {
      buffer
        ..write(' ${connection.domain} ${connection.dst}')
        ..write(' out=${connection.outbound} rule=${connection.rule}')
        ..write(
          ' up=${connection.uploadBytes} down=${connection.downloadBytes}',
        );
    }
    final dns = record.dns;
    if (dns != null) {
      buffer.write(' ${dns.domain} ${dns.qtype} ${dns.rcode}');
    }
    if (record.message.isNotEmpty) buffer.write(' ${record.message}');
    return buffer.toString();
  }
}

/// 区块标题（使用 [ColoredAliIcon] 为 COLR 图标染色）。
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.icon,
    required this.title,
    required this.trailing,
  });

  final IconData icon;
  final String title;
  final String trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: AppSpacing.onlyVerticalMD,
      child: Row(
        children: [
          ColoredAliIcon(
            icon: icon,
            size: AppTypography.iconLG,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(title, style: theme.textTheme.titleSmall),
          ),
          Text(
            trailing,
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _LiveLogTile extends StatelessWidget {
  const _LiveLogTile({
    super.key,
    required this.entry,
    required this.onCopy,
    required this.onTap,
  });

  final LogEntry entry;
  final VoidCallback onCopy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final color = switch (entry.level) {
      LogLevel.debug => scheme.onSurfaceVariant,
      LogLevel.info => scheme.primary,
      LogLevel.warning => scheme.tertiary,
      LogLevel.error => scheme.error,
      LogLevel.all => scheme.onSurfaceVariant,
    };
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: AppSpacing.onlyVerticalXS,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              entry.timeString,
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Text(
              entry.level.label,
              style: theme.textTheme.labelSmall?.copyWith(color: color),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(entry.message, style: theme.textTheme.bodySmall),
                  if (entry.data != null && entry.data!.isNotEmpty)
                    Text(
                      entry.data.toString(),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              tooltip: '复制',
              icon: const Icon(Icons.copy, size: AppTypography.iconSM),
              onPressed: onCopy,
            ),
          ],
        ),
      ),
    );
  }
}

class _StructuredLogTile extends StatelessWidget {
  const _StructuredLogTile({
    super.key,
    required this.record,
    required this.onCopy,
    required this.onTap,
  });

  final LogRecord record;
  final VoidCallback onCopy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final connection = record.connection;
    final dns = record.dns;

    final title = connection != null
        ? (connection.domain.isEmpty ? connection.dst : connection.domain)
        : dns != null
            ? (dns.domain.isEmpty ? '(未知域名)' : dns.domain)
            : record.message;
    final subtitleParts = <String>[
      record.kind.wire,
      if (connection != null && connection.outbound.isNotEmpty)
        'out=${connection.outbound}',
      if (connection != null && connection.rule.isNotEmpty)
        '${connection.rule} ${connection.rulePayload}'.trim(),
      if (dns != null && dns.rcode.isNotEmpty) dns.rcode,
      if (dns != null) '${dns.latencyMs} ms',
    ];

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
                        Expanded(
                          child: Text(
                            title.isEmpty ? '(空)' : title,
                            style: theme.textTheme.bodyMedium,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Text(
                          _formatTime(record.tsMs),
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      subtitleParts.join(' · '),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (connection != null &&
                        (connection.uploadBytes > 0 ||
                            connection.downloadBytes > 0)) ...[
                      const SizedBox(height: AppSpacing.xs),
                      Text(
                        '↑ ${byteSize(connection.uploadBytes)}  ↓ ${byteSize(connection.downloadBytes)}',
                        style: theme.textTheme.labelSmall,
                      ),
                    ],
                    if (connection?.error != null) ...[
                      const SizedBox(height: AppSpacing.xs),
                      Text(
                        connection!.error!,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: scheme.error,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: '复制',
                icon: const Icon(Icons.copy, size: AppTypography.iconSM),
                onPressed: onCopy,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 结构化记录详情（弹层内容，完整字段）。
class _RecordDetailContent extends StatelessWidget {
  const _RecordDetailContent({required this.record});

  final LogRecord record;

  @override
  Widget build(BuildContext context) {
    final connection = record.connection;
    final dns = record.dns;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _DetailField(label: '时间', value: _formatDateTime(record.tsMs)),
        _DetailField(label: '级别', value: record.level.wire),
        _DetailField(label: '类别', value: record.kind.wire),
        if (record.message.isNotEmpty)
          _DetailField(label: '消息', value: record.message),
        if (connection != null) ...[
          _DetailField(label: '连接 ID', value: connection.id),
          _DetailField(label: '方向', value: connection.direction),
          _DetailField(label: '域名', value: connection.domain),
          _DetailField(label: '出站', value: connection.outbound),
          _DetailField(
            label: '规则',
            value: '${connection.rule} ${connection.rulePayload}'.trim(),
          ),
          _DetailField(label: '网络', value: connection.network),
          _DetailField(label: '源地址', value: connection.src),
          _DetailField(label: '目标地址', value: connection.dst),
          _DetailField(label: '上传', value: byteSize(connection.uploadBytes)),
          _DetailField(label: '下载', value: byteSize(connection.downloadBytes)),
          _DetailField(label: '总计', value: byteSize(connection.bytes)),
          _DetailField(label: '耗时', value: '${connection.durationMs} ms'),
          if (connection.error != null)
            _DetailField(label: '错误', value: connection.error!),
        ],
        if (dns != null) ...[
          _DetailField(label: '域名', value: dns.domain),
          _DetailField(label: '类型', value: dns.qtype),
          _DetailField(label: '结果码', value: dns.rcode),
          _DetailField(label: '解析器', value: dns.resolver),
          _DetailField(label: '延迟', value: '${dns.latencyMs} ms'),
          _DetailField(label: '成功', value: dns.ok ? '是' : '否'),
          _DetailField(label: '模式', value: dns.mode),
          if (dns.answers.isNotEmpty)
            _DetailField(label: '应答', value: dns.answers.join(', ')),
          if (dns.note != null) _DetailField(label: '备注', value: dns.note!),
        ],
      ],
    );
  }
}

/// 模块实时消息详情（弹层内容）。
class _LiveDetailContent extends StatelessWidget {
  const _LiveDetailContent({required this.entry});

  final LogEntry entry;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _DetailField(label: '时间', value: entry.dateTimeString),
        _DetailField(label: '级别', value: entry.level.label),
        _DetailField(label: '消息', value: entry.message),
        if (entry.data != null)
          _DetailField(label: '数据', value: entry.data.toString()),
      ],
    );
  }
}

/// 详情字段：标签 + 值（值用等宽字体，便于阅读日志内容）。
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
            Icon(icon, size: AppTypography.iconXXXL, color: scheme.onSurfaceVariant),
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

/// 毫秒时间戳 → `HH:mm:ss`（0 = 无时间）。
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
