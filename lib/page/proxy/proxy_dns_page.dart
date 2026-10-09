import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';

import 'package:gstore/core/design/app_components.dart';
import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/design/app_radius.dart';
import 'package:gstore/core/design/app_sheet.dart';
import 'package:gstore/core/design/app_spacing.dart';
import 'package:gstore/core/design/app_typography.dart';
import 'package:gstore/core/rust/proxy/ProxyContract.dart';
import 'package:gstore/core/rust/proxy/ProxyModule.dart';

import 'proxy_dns_facade.dart';

/// DNS 设置页（纯展示 / 触发层）。
///
/// 读取 `dns.get` 的**有效配置 + 统计 + 近期查询/映射**，编辑表单经统一
/// 底部弹层（[AppSheet]）呈现并 `dns.set` 保存；清空缓存走
/// [AppDialogs.showConfirmSheet]（危险操作）后 `dns.clear_cache`。
///
/// 所有解析 / 网络 / 路由逻辑都在 Rust 侧（`API.md` §2.7），本页只翻译。
/// 门面经构造函数注入，测试无需原生模块。
class ProxyDnsPage extends StatefulWidget {
  const ProxyDnsPage({super.key, this.facade});

  /// 代理模块门面（测试可注入假实现；为空时用生产适配器）。
  final ProxyDnsFacade? facade;

  @override
  State<ProxyDnsPage> createState() => _ProxyDnsPageState();
}

class _ProxyDnsPageState extends State<ProxyDnsPage> {
  late final ProxyDnsFacade _facade;

  /// 近期查询 / 映射每次展开的增量（初始即展示这么多，之后按需累加）。
  static const int _pageChunk = 20;

  bool _loading = true;
  String? _error;
  DnsSnapshot? _snapshot;

  /// 已展开的条数（去除 20 条硬截断；「显示更多」累加）。
  int _queryVisible = _pageChunk;
  int _mappingVisible = _pageChunk;

  @override
  void initState() {
    super.initState();
    _facade = widget.facade ?? ProxyModuleDnsFacade();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final snapshot = await _facade.dnsGet();
      if (!mounted) return;
      setState(() {
        _snapshot = snapshot;
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
        _error = 'DNS 配置加载失败：$error';
        _loading = false;
      });
    }
  }

  Future<void> _openEditSheet() async {
    final saved = await AppSheet.showCustom<bool>(
      context: context,
      builder: (sheetContext) => _DnsFormSheet(
        facade: _facade,
        initial: _snapshot?.config,
      ),
    );
    if (!mounted || saved != true) return;
    AppDialogs.showSuccess('DNS 配置已保存');
    await _load();
  }

  Future<void> _confirmClearCache() async {
    final ok = await AppDialogs.showConfirmSheet(
      title: '清空 DNS 缓存',
      message: '将清空 DNS 缓存与 fake-IP 分配，确定继续吗？',
      confirmText: '清空',
      isDangerous: true,
      icon: const Icon(TablerIcons.clear_all),
    );
    if (ok != true || !mounted) return;
    try {
      final result = await _facade.dnsClearCache();
      if (!mounted) return;
      AppDialogs.showSuccess('已清空 ${result.flushed} 条缓存');
      await _load();
    } on ProxyModuleException catch (error) {
      AppDialogs.showError(error.message, title: '清空失败');
    } catch (error) {
      AppDialogs.showError('清空缓存失败：$error');
    }
  }

  Future<void> _copyText(String text, String label) async {
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    AppDialogs.showSuccess('已复制$label');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('DNS 设置'),
        actions: [
          IconButton(
            tooltip: '编辑',
            icon: const Icon(TablerIcons.pencil),
            onPressed: _snapshot == null ? null : _openEditSheet,
          ),
          IconButton(
            tooltip: '清空缓存',
            icon: const Icon(TablerIcons.clear_all),
            onPressed: _snapshot == null ? null : _confirmClearCache,
          ),
        ],
      ),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) {
      return const Center(child: AppLoading(size: AppLoadingSize.medium));
    }
    final error = _error;
    if (error != null) {
      return _MessageState(
        icon: TablerIcons.alert_circle,
        title: 'DNS 不可用',
        message: error,
        actionLabel: '重试',
        onAction: _load,
      );
    }
    final snapshot = _snapshot;
    if (snapshot == null) {
      return const _MessageState(
        icon: TablerIcons.server,
        title: '暂无 DNS 配置',
        message: 'DNS 配置读取为空。',
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: AppSpacing.allLG,
        children: [
          _buildConfigCard(context, snapshot),
          const SizedBox(height: AppSpacing.lg),
          _buildStatsCard(context, snapshot),
          const SizedBox(height: AppSpacing.lg),
          _buildRecentQueries(context, snapshot),
          const SizedBox(height: AppSpacing.lg),
          _buildMappings(context, snapshot),
        ],
      ),
    );
  }

  Widget _buildConfigCard(BuildContext context, DnsSnapshot snapshot) {
    final theme = Theme.of(context);
    final config = snapshot.config;
    final mode = snapshot.mode.isNotEmpty ? snapshot.mode : config.mode;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: AppSpacing.allLG,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                ColoredAliIcon(
                  icon: TablerIcons.link,
                  size: AppTypography.iconXL,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Text('解析模式', style: theme.textTheme.titleSmall),
                ),
                _ModeBadge(mode: mode.isEmpty ? '未知' : mode),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            _ListSection(title: 'nameserver', values: config.nameservers),
            _ListSection(title: 'fallback', values: config.fallback),
            _ListSection(title: 'DoH', values: config.doh),
            _ListSection(title: 'DoT', values: config.dot),
            _ListSection(title: 'bootstrap', values: config.defaultNameservers),
            if (config.fakeIpRange != null || config.fakeIpRangeV6 != null)
              _kv(
                theme,
                'fake-IP 范围',
                [
                  if (config.fakeIpRange != null) config.fakeIpRange!,
                  if (config.fakeIpRangeV6 != null) config.fakeIpRangeV6!,
                ].join(' / '),
              ),
            if (config.fakeIpTtlMs != null)
              _kv(theme, 'fake-IP TTL', '${config.fakeIpTtlMs} ms'),
            _ListSection(title: 'fake-IP 过滤', values: config.fakeIpFilter),
            if (config.fakeIpFilterMode != null)
              _kv(theme, '过滤模式', config.fakeIpFilterMode!),
            _kv(theme, 'use-hosts', config.useHosts ? '开启' : '关闭'),
            _kv(theme, 'ipv6', config.ipv6 ? '开启' : '关闭'),
            _kv(theme, 'hijack', config.hijack ? '开启' : '关闭'),
            if (config.hosts.isNotEmpty)
              _kv(theme, 'hosts', '${config.hosts.length} 条'),
          ],
        ),
      ),
    );
  }

  Widget _buildStatsCard(BuildContext context, DnsSnapshot snapshot) {
    final theme = Theme.of(context);
    final stats = snapshot.stats;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: AppSpacing.allLG,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('缓存统计', style: theme.textTheme.titleSmall),
            const SizedBox(height: AppSpacing.sm),
            _kv(theme, '查询数', '${stats.queries}'),
            _kv(theme, '失败数', '${stats.failures}'),
            _kv(theme, '缓存条数', '${stats.cacheEntries}'),
            _kv(
              theme,
              'fake-IP',
              stats.fakeIpActive
                  ? (stats.fakeIpRange?.isNotEmpty == true
                      ? '启用（${stats.fakeIpRange}）'
                      : '启用')
                  : '未启用',
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRecentQueries(BuildContext context, DnsSnapshot snapshot) {
    final theme = Theme.of(context);
    final queries = snapshot.recentQueries;
    final shown = queries.take(_queryVisible).toList();
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: AppSpacing.allLG,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('近期查询', style: theme.textTheme.titleSmall),
                ),
                Text(
                  '共 ${queries.length} 条',
                  key: const Key('dns_query_count'),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            if (queries.isEmpty)
              Text(
                '暂无 DNS 查询记录',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              )
            else ...[
              for (var i = 0; i < shown.length; i++)
                _DnsQueryTile(
                  key: Key('dns_query_$i'),
                  index: i,
                  record: shown[i],
                  onCopy: () => _copyText(shown[i].domain, '查询域名'),
                ),
              if (queries.length > shown.length)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    key: const Key('dns_queries_more'),
                    onPressed: () => setState(
                      () => _queryVisible += _pageChunk,
                    ),
                    child: Text(
                      '显示更多（已显示 ${shown.length} / 共 ${queries.length}）',
                    ),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildMappings(BuildContext context, DnsSnapshot snapshot) {
    final theme = Theme.of(context);
    final mappings = snapshot.mappings;
    final shown = mappings.take(_mappingVisible).toList();
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: AppSpacing.allLG,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('域名映射', style: theme.textTheme.titleSmall),
                ),
                Text(
                  '共 ${mappings.length} 条',
                  key: const Key('dns_mapping_count'),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            if (mappings.isEmpty)
              Text(
                '暂无域名映射',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              )
            else ...[
              for (var i = 0; i < shown.length; i++)
                Padding(
                  key: Key('dns_mapping_$i'),
                  padding: AppSpacing.onlyVerticalXS,
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          shown[i].domain.isEmpty
                              ? shown[i].ip
                              : shown[i].domain,
                          style: theme.textTheme.bodyMedium,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      Text(
                        shown[i].ip,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      if (shown[i].fake) ...[
                        const SizedBox(width: AppSpacing.sm),
                        Text(
                          'fake',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.primary,
                          ),
                        ),
                      ],
                      IconButton(
                        key: Key('dns_copy_mapping_$i'),
                        tooltip: '复制映射',
                        iconSize: AppTypography.iconSM,
                        visualDensity: VisualDensity.compact,
                        onPressed: () => _copyText(
                          shown[i].domain.isEmpty
                              ? shown[i].ip
                              : '${shown[i].domain} ${shown[i].ip}',
                          '映射',
                        ),
                        icon: Icon(
                          TablerIcons.copy,
                          color: theme.colorScheme.primary,
                        ),
                      ),
                    ],
                  ),
                ),
              if (mappings.length > shown.length)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    key: const Key('dns_mappings_more'),
                    onPressed: () => setState(
                      () => _mappingVisible += _pageChunk,
                    ),
                    child: Text(
                      '显示更多（已显示 ${shown.length} / 共 ${mappings.length}）',
                    ),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _kv(ThemeData theme, String label, String value) {
    return Padding(
      padding: AppSpacing.onlyVerticalXS,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: theme.textTheme.bodyMedium),
          const SizedBox(width: AppSpacing.md),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: theme.textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }
}

/// `nameserver` 等列表小节（空列表显示占位）。
class _ListSection extends StatelessWidget {
  const _ListSection({required this.title, required this.values});

  final String title;
  final List<String> values;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: AppSpacing.onlyVerticalXS,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 88,
            child: Text(title, style: theme.textTheme.bodyMedium),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              values.isEmpty ? '—' : values.join('\n'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: values.isEmpty
                    ? theme.colorScheme.onSurfaceVariant
                    : theme.colorScheme.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ModeBadge extends StatelessWidget {
  const _ModeBadge({required this.mode});

  final String mode;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: AppSpacing.horizontalSM_verticalXS,
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: AppRadius.allMD,
      ),
      child: Text(
        mode,
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: scheme.onPrimaryContainer,
            ),
      ),
    );
  }
}

class _DnsQueryTile extends StatelessWidget {
  const _DnsQueryTile({
    super.key,
    required this.index,
    required this.record,
    required this.onCopy,
  });

  final int index;
  final DnsQueryRecord record;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final ok = record.ok;
    return Padding(
      padding: AppSpacing.onlyVerticalXS,
      child: Row(
        children: [
          Icon(
            ok ? TablerIcons.circle_check : TablerIcons.alert_circle,
            size: AppTypography.iconSM,
            color: ok ? scheme.primary : scheme.error,
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  record.domain.isEmpty ? '(未知)' : record.domain,
                  style: theme.textTheme.bodyMedium,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  [
                    if (record.qtype.isNotEmpty) record.qtype,
                    if (record.rcode.isNotEmpty) record.rcode,
                    if (record.resolver.isNotEmpty) record.resolver,
                  ].join(' · '),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                if (record.answers.isNotEmpty)
                  Text(
                    record.answers.join(', '),
                    key: Key('dns_query_answers_$index'),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Text(
            '${record.latencyMs} ms',
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          IconButton(
            key: Key('dns_copy_query_$index'),
            tooltip: '复制查询',
            iconSize: AppTypography.iconSM,
            visualDensity: VisualDensity.compact,
            onPressed: onCopy,
            icon: Icon(TablerIcons.copy, color: scheme.primary),
          ),
        ],
      ),
    );
  }
}

/// DNS 编辑表单弹层（自带 context，经 [AppSheetScaffold] 的 actions 关闭）。
class _DnsFormSheet extends StatefulWidget {
  const _DnsFormSheet({required this.facade, this.initial});

  final ProxyDnsFacade facade;
  final DnsConfig? initial;

  @override
  State<_DnsFormSheet> createState() => _DnsFormSheetState();
}

class _DnsFormSheetState extends State<_DnsFormSheet> {
  late String _mode;
  late final TextEditingController _nameservers;
  late final TextEditingController _fallback;
  late final TextEditingController _doh;
  late final TextEditingController _dot;
  late final TextEditingController _bootstrap;
  late final TextEditingController _fakeIpRange;
  late final TextEditingController _fakeIpRangeV6;
  late final TextEditingController _fakeIpTtl;
  late final TextEditingController _fakeIpFilter;
  late final TextEditingController _hosts;
  late String _filterMode;
  late bool _useHosts;
  late bool _ipv6;
  late bool _hijack;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    _mode = (initial?.mode.isNotEmpty ?? false) ? initial!.mode : 'fake-ip';
    _nameservers = TextEditingController(text: _join(initial?.nameservers));
    _fallback = TextEditingController(text: _join(initial?.fallback));
    _doh = TextEditingController(text: _join(initial?.doh));
    _dot = TextEditingController(text: _join(initial?.dot));
    _bootstrap = TextEditingController(text: _join(initial?.defaultNameservers));
    _fakeIpRange = TextEditingController(text: initial?.fakeIpRange ?? '');
    _fakeIpRangeV6 = TextEditingController(text: initial?.fakeIpRangeV6 ?? '');
    _fakeIpTtl =
        TextEditingController(text: initial?.fakeIpTtlMs?.toString() ?? '');
    _fakeIpFilter = TextEditingController(text: _join(initial?.fakeIpFilter));
    _hosts = TextEditingController(text: _joinHosts(initial?.hosts));
    _filterMode = initial?.fakeIpFilterMode == 'whitelist'
        ? 'whitelist'
        : 'blacklist';
    _useHosts = initial?.useHosts ?? true;
    _ipv6 = initial?.ipv6 ?? true;
    _hijack = initial?.hijack ?? true;
  }

  @override
  void dispose() {
    _nameservers.dispose();
    _fallback.dispose();
    _doh.dispose();
    _dot.dispose();
    _bootstrap.dispose();
    _fakeIpRange.dispose();
    _fakeIpRangeV6.dispose();
    _fakeIpTtl.dispose();
    _fakeIpFilter.dispose();
    _hosts.dispose();
    super.dispose();
  }

  static String _join(List<String>? values) =>
      values == null || values.isEmpty ? '' : values.join('\n');

  static List<String> _parse(String raw) => raw
      .split(RegExp(r'[\n,]+'))
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList();

  /// 空文本 → null（可选标量字段的「清空」语义）。
  static String? _emptyToNull(String raw) {
    final trimmed = raw.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  /// `hosts` 展示：每行 `domain ip1,ip2`。
  static String _joinHosts(Map<String, List<String>>? hosts) {
    if (hosts == null || hosts.isEmpty) return '';
    return hosts.entries
        .map((entry) => '${entry.key} ${entry.value.join(',')}')
        .join('\n');
  }

  /// `hosts` 解析：每行 `domain ip1,ip2`；空行 / 格式不完整行安全忽略。
  static Map<String, List<String>> _parseHosts(String raw) {
    final result = <String, List<String>>{};
    for (final line in raw.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      final parts = trimmed.split(RegExp(r'\s+'));
      if (parts.length < 2) continue;
      final domain = parts.first;
      final ips = parts
          .sublist(1)
          .join(',')
          .split(',')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();
      if (domain.isEmpty || ips.isEmpty) continue;
      result[domain] = ips;
    }
    return result;
  }

  Future<void> _save() async {
    final ttlRaw = _fakeIpTtl.text.trim();
    final ttl = ttlRaw.isEmpty ? null : int.tryParse(ttlRaw);
    if (ttlRaw.isNotEmpty && ttl == null) {
      AppDialogs.showError('fake-IP TTL 需为整数（毫秒）', title: '保存失败');
      return;
    }
    setState(() => _saving = true);
    try {
      // 显式提交全部编辑字段（含空列表 / 空 map / null）以保证「清空」语义正确。
      final result = await widget.facade.dnsSet(<String, dynamic>{
        'mode': _mode,
        'nameservers': _parse(_nameservers.text),
        'fallback': _parse(_fallback.text),
        'doh': _parse(_doh.text),
        'dot': _parse(_dot.text),
        'defaultNameservers': _parse(_bootstrap.text),
        'fakeIpRange': _emptyToNull(_fakeIpRange.text),
        'fakeIpRangeV6': _emptyToNull(_fakeIpRangeV6.text),
        'fakeIpTtlMs': ttl,
        'fakeIpFilter': _parse(_fakeIpFilter.text),
        'fakeIpFilterMode': _filterMode,
        'useHosts': _useHosts,
        'ipv6': _ipv6,
        'hijack': _hijack,
        'hosts': _parseHosts(_hosts.text),
      });
      if (!mounted) return;
      if (!result.ok) {
        setState(() => _saving = false);
        AppDialogs.showError('DNS 配置保存失败');
        return;
      }
      Navigator.of(context).pop(true);
    } on ProxyModuleException catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      AppDialogs.showError(error.message, title: '保存失败');
    } catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      AppDialogs.showError('DNS 配置保存失败：$error');
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppSheetScaffold(
      title: 'DNS 配置',
      subtitle: '修改解析模式、上游与 DoH/DoT 地址',
      icon: const ColoredAliIcon(icon: TablerIcons.link),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? const AppLoading(size: AppLoadingSize.small)
              : const Text('保存'),
        ),
      ],
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('解析模式', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: AppSpacing.sm),
          AppSegmentedButton<String>(
            value: _mode,
            enabled: !_saving,
            segments: const [
              AppSegment(value: 'fake-ip', label: 'fake-ip'),
              AppSegment(value: 'redir-host', label: 'redir-host'),
              AppSegment(value: 'normal', label: 'normal'),
            ],
            onChanged: (value) => setState(() => _mode = value),
          ),
          const SizedBox(height: AppSpacing.lg),
          _BuildField(
            key: const Key('dns_nameservers_field'),
            controller: _nameservers,
            label: 'nameserver',
            hint: '每行一个，如 1.1.1.1',
            enabled: !_saving,
          ),
          const SizedBox(height: AppSpacing.md),
          _BuildField(
            key: const Key('dns_fallback_field'),
            controller: _fallback,
            label: 'fallback',
            hint: '每行一个',
            enabled: !_saving,
          ),
          const SizedBox(height: AppSpacing.md),
          _BuildField(
            key: const Key('dns_doh_field'),
            controller: _doh,
            label: 'DoH',
            hint: 'https://dns.example/dns-query',
            enabled: !_saving,
          ),
          const SizedBox(height: AppSpacing.md),
          _BuildField(
            key: const Key('dns_dot_field'),
            controller: _dot,
            label: 'DoT',
            hint: 'tls://1.1.1.1:853',
            enabled: !_saving,
          ),
          const SizedBox(height: AppSpacing.md),
          _BuildField(
            key: const Key('dns_bootstrap_field'),
            controller: _bootstrap,
            label: 'bootstrap',
            hint: '每行一个，如 223.5.5.5',
            enabled: !_saving,
          ),
          const SizedBox(height: AppSpacing.lg),
          Text('fake-IP', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: AppSpacing.sm),
          _BuildField(
            key: const Key('dns_fake_ip_range_field'),
            controller: _fakeIpRange,
            label: 'fake-IP 范围（IPv4）',
            hint: '如 198.18.0.0/16（留空清除）',
            enabled: !_saving,
          ),
          const SizedBox(height: AppSpacing.md),
          _BuildField(
            key: const Key('dns_fake_ip_range_v6_field'),
            controller: _fakeIpRangeV6,
            label: 'fake-IP 范围（IPv6）',
            hint: '如 fdfe:dcba:9876::/48（留空清除）',
            enabled: !_saving,
          ),
          const SizedBox(height: AppSpacing.md),
          _BuildField(
            key: const Key('dns_fake_ip_ttl_field'),
            controller: _fakeIpTtl,
            label: 'fake-IP TTL（毫秒）',
            hint: '留空清除',
            enabled: !_saving,
            keyboardType: TextInputType.number,
          ),
          const SizedBox(height: AppSpacing.md),
          _BuildField(
            key: const Key('dns_fake_ip_filter_field'),
            controller: _fakeIpFilter,
            label: 'fake-IP 过滤',
            hint: '每行一个域名 / 规则',
            enabled: !_saving,
          ),
          const SizedBox(height: AppSpacing.md),
          Text('过滤模式', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: AppSpacing.sm),
          AppSegmentedButton<String>(
            key: const Key('dns_fake_ip_filter_mode'),
            value: _filterMode,
            enabled: !_saving,
            segments: const [
              AppSegment(
                value: 'blacklist',
                label: 'blacklist',
                key: Key('dns_fake_ip_filter_mode_blacklist'),
              ),
              AppSegment(
                value: 'whitelist',
                label: 'whitelist',
                key: Key('dns_fake_ip_filter_mode_whitelist'),
              ),
            ],
            onChanged: (value) => setState(() => _filterMode = value),
          ),
          const SizedBox(height: AppSpacing.lg),
          Text('开关', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: AppSpacing.xs),
          _SwitchField(
            key: const Key('dns_use_hosts_switch'),
            label: 'use-hosts',
            value: _useHosts,
            enabled: !_saving,
            onChanged: (value) => setState(() => _useHosts = value),
          ),
          _SwitchField(
            key: const Key('dns_ipv6_switch'),
            label: 'ipv6',
            value: _ipv6,
            enabled: !_saving,
            onChanged: (value) => setState(() => _ipv6 = value),
          ),
          _SwitchField(
            key: const Key('dns_hijack_switch'),
            label: 'hijack',
            value: _hijack,
            enabled: !_saving,
            onChanged: (value) => setState(() => _hijack = value),
          ),
          const SizedBox(height: AppSpacing.md),
          _BuildField(
            key: const Key('dns_hosts_field'),
            controller: _hosts,
            label: 'hosts 映射',
            hint: '每行「域名 ip1,ip2」，如 example.com 1.2.3.4,5.6.7.8',
            enabled: !_saving,
            maxLines: 4,
          ),
        ],
      ),
    );
  }
}

/// 开关行（统一令牌；测试按 [Key] 点击切换）。
class _SwitchField extends StatelessWidget {
  const _SwitchField({
    super.key,
    required this.label,
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  final String label;
  final bool value;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(label),
        value: value,
        onChanged: enabled ? onChanged : null,
      ),
    );
  }
}

class _BuildField extends StatelessWidget {
  const _BuildField({
    super.key,
    required this.controller,
    required this.label,
    required this.hint,
    required this.enabled,
    this.keyboardType = TextInputType.multiline,
    this.maxLines = 3,
  });

  final TextEditingController controller;
  final String label;
  final String hint;
  final bool enabled;
  final TextInputType keyboardType;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      enabled: enabled,
      minLines: 1,
      maxLines: maxLines,
      keyboardType: keyboardType,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
      ),
    );
  }
}

/// 通用空 / 错误态（显式文案，非空白）。
class _MessageState extends StatelessWidget {
  const _MessageState({
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
