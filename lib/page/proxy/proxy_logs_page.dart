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

/// 代理日志查看器（纯展示 / 触发层）。
///
/// * **实时模块日志**：`LogManager` 推送流（模块经宿主 log 回调接入）。
/// * **结构化记录**：`log.get` 的连接 / DNS 结构化条目。
/// * 级别筛选经 `log.set_level` 生效，另提供搜索与复制。
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

class _ProxyLogsPageState extends State<ProxyLogsPage> {
  late final ProxyLogsFacade _facade;
  late final ProxyLogSource _logSource;

  final TextEditingController _searchController = TextEditingController();

  StreamSubscription<List<LogEntry>>? _logSub;

  ProxyLogLevel _level = ProxyLogLevel.info;
  String _query = '';
  bool _loading = true;
  String? _error;
  List<LogEntry> _liveLogs = const <LogEntry>[];
  List<LogRecord> _records = const <LogRecord>[];

  @override
  void initState() {
    super.initState();
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
    _logSub?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await _facade.logGet(
        LogGetRequest(level: _level.wire, limit: 500),
      );
      if (!mounted) return;
      setState(() {
        _records = page.records
            .where((record) => record.kind != ProxyLogKind.message)
            .toList();
        _loading = false;
      });
    } on ProxyModuleException catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.message;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = '日志加载失败：$error';
        _loading = false;
      });
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

  List<LogEntry> get _filteredLiveLogs {
    final minRank = _levelRank(_level);
    return _liveLogs.where((entry) {
      if (_logEntryRank(entry) < minRank) return false;
      final data = entry.data?.toString() ?? '';
      return _matchesQuery('${entry.message} $data');
    }).toList();
  }

  List<LogRecord> get _filteredRecords {
    final minRank = _levelRank(_level);
    return _records.where((record) {
      if (_levelRank(record.level) < minRank) return false;
      final connection = record.connection;
      final dns = record.dns;
      return _matchesQuery([
        record.message,
        if (connection != null) connection.domain,
        if (connection != null) connection.outbound,
        if (connection != null) connection.rule,
        if (connection != null) connection.rulePayload,
        if (connection != null) connection.dst,
        if (dns != null) dns.domain,
      ].join(' '));
    }).toList();
  }

  Future<void> _copy(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    AppDialogs.showSuccess('已复制到剪贴板');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('代理日志'),
        actions: [
          IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _load,
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
                TextField(
                  key: const Key('log_search_field'),
                  controller: _searchController,
                  onChanged: (value) => setState(() => _query = value.trim()),
                  decoration: const InputDecoration(
                    labelText: '搜索',
                    hintText: '域名 / 出站 / 规则 / 内容',
                    prefixIcon: Icon(Icons.search),
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
        onAction: _load,
      );
    }

    final live = _filteredLiveLogs;
    final records = _filteredRecords;
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
        message: '当前级别或搜索条件没有匹配的日志。',
      );
    }

    return ListView(
      padding: AppSpacing.onlyHorizontalLG,
      children: [
        if (live.isNotEmpty) ...[
          _SectionHeader(
            icon: AliIcon.history,
            title: '模块日志',
            trailing: '${live.length}',
          ),
          for (final entry in live)
            _LiveLogTile(
              key: ValueKey('live_log_${entry.timestamp.microsecondsSinceEpoch}'),
              entry: entry,
              onCopy: () => _copy(entry.toFormattedString()),
            ),
        ],
        if (records.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.sm),
          _SectionHeader(
            icon: AliIcon.database,
            title: '结构化记录（连接 / DNS）',
            trailing: '${records.length}',
          ),
          for (final record in records)
            _StructuredLogTile(
              key: ValueKey('structured_log_${record.cursor}'),
              record: record,
              onCopy: () => _copy(_formatRecord(record)),
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
  const _LiveLogTile({super.key, required this.entry, required this.onCopy});

  final LogEntry entry;
  final VoidCallback onCopy;

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
    return Padding(
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
    );
  }
}

class _StructuredLogTile extends StatelessWidget {
  const _StructuredLogTile({
    super.key,
    required this.record,
    required this.onCopy,
  });

  final LogRecord record;
  final VoidCallback onCopy;

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

/// 毫秒时间戳 → `HH:mm:ss`（0 = 无时间）。
String _formatTime(int tsMs) {
  if (tsMs <= 0) return '';
  final time = DateTime.fromMillisecondsSinceEpoch(tsMs).toLocal();
  return '${time.hour.toString().padLeft(2, '0')}:'
      '${time.minute.toString().padLeft(2, '0')}:'
      '${time.second.toString().padLeft(2, '0')}';
}
