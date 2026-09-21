import 'package:flutter/material.dart';

import 'package:gstore/core/design/app_components.dart';
import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/design/app_radius.dart';
import 'package:gstore/core/design/app_sheet.dart';
import 'package:gstore/core/design/app_spacing.dart';
import 'package:gstore/core/design/app_typography.dart';
import 'package:gstore/core/icons/Icons.dart';
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

  bool _loading = true;
  String? _error;
  DnsSnapshot? _snapshot;

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
      icon: const Icon(Icons.cleaning_services_outlined),
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('DNS 设置'),
        actions: [
          IconButton(
            tooltip: '编辑',
            icon: const Icon(Icons.edit_outlined),
            onPressed: _snapshot == null ? null : _openEditSheet,
          ),
          IconButton(
            tooltip: '清空缓存',
            icon: const Icon(Icons.cleaning_services_outlined),
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
        icon: Icons.error_outline,
        title: 'DNS 不可用',
        message: error,
        actionLabel: '重试',
        onAction: _load,
      );
    }
    final snapshot = _snapshot;
    if (snapshot == null) {
      return const _MessageState(
        icon: Icons.dns_outlined,
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
                  icon: AliIcon.link,
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
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: AppSpacing.allLG,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('近期查询', style: theme.textTheme.titleSmall),
            const SizedBox(height: AppSpacing.sm),
            if (snapshot.recentQueries.isEmpty)
              Text(
                '暂无 DNS 查询记录',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              )
            else
              for (final record in snapshot.recentQueries.take(20))
                _DnsQueryTile(record: record),
          ],
        ),
      ),
    );
  }

  Widget _buildMappings(BuildContext context, DnsSnapshot snapshot) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: AppSpacing.allLG,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('域名映射', style: theme.textTheme.titleSmall),
            const SizedBox(height: AppSpacing.sm),
            if (snapshot.mappings.isEmpty)
              Text(
                '暂无域名映射',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              )
            else
              for (final mapping in snapshot.mappings.take(20))
                Padding(
                  padding: AppSpacing.onlyVerticalXS,
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          mapping.domain.isEmpty ? mapping.ip : mapping.domain,
                          style: theme.textTheme.bodyMedium,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      Text(
                        mapping.ip,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      if (mapping.fake) ...[
                        const SizedBox(width: AppSpacing.sm),
                        Text(
                          'fake',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.primary,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
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
  const _DnsQueryTile({required this.record});

  final DnsQueryRecord record;

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
            ok ? Icons.check_circle_outline : Icons.error_outline,
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
  }

  @override
  void dispose() {
    _nameservers.dispose();
    _fallback.dispose();
    _doh.dispose();
    _dot.dispose();
    super.dispose();
  }

  static String _join(List<String>? values) =>
      values == null || values.isEmpty ? '' : values.join('\n');

  static List<String> _parse(String raw) => raw
      .split(RegExp(r'[\n,]+'))
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList();

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      // 显式提交各列表（含空列表）以保证「清空」语义正确。
      final result = await widget.facade.dnsSet(<String, dynamic>{
        'mode': _mode,
        'nameservers': _parse(_nameservers.text),
        'fallback': _parse(_fallback.text),
        'doh': _parse(_doh.text),
        'dot': _parse(_dot.text),
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
      icon: const ColoredAliIcon(icon: AliIcon.link),
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
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'fake-ip', label: Text('fake-ip')),
              ButtonSegment(value: 'redir-host', label: Text('redir-host')),
              ButtonSegment(value: 'normal', label: Text('normal')),
            ],
            selected: {_mode},
            showSelectedIcon: false,
            onSelectionChanged: _saving
                ? null
                : (selection) => setState(() => _mode = selection.first),
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
        ],
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
  });

  final TextEditingController controller;
  final String label;
  final String hint;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      enabled: enabled,
      minLines: 1,
      maxLines: 3,
      keyboardType: TextInputType.multiline,
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
