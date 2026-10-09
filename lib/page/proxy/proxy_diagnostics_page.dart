/// 诊断 / 日志 / 规则查看器 + config 手动触发（Todo 30，纯展示 / 触发层）。
///
/// 四个相互独立的小节，全部经窄接口 [ProxyDiagnosticsFacade] 消费冻结的模块
/// 方法（`API.md` §2.8 / §2.11 / §2.5 / §2.13）；Dart 只做「拉取 → 展示 →
/// 触发」，不解析 / 不聚合 / 不落盘。
///
/// * **Clash 回环控制器**（`diagnostics.clash_api.*`）：**明确标注「仅用于诊断」**。
///   它默认关闭，启动需隧道运行；Dart 侧**绝不**经其 HTTP API 处理正常业务。
/// * **日志查看器**（`log.get` / `log.clear` / `log.set_level`）：按级别过滤、
///   危险确认后清空。
/// * **规则查看器**（`rules.get` / `rules.reload`）：展示已解析规则；手动重载经
///   统一底部弹层粘贴内联 config。
/// * **config 触发**（`config.generate` / `config.apply`）：手动渲染 / 热应用，
///   只展示摘要（format / hash / 计数 / 警告）——**绝不渲染配置正文**（其中可能
///   含代理凭证，避免暴露密钥）。
///
/// 门面经构造函数注入，测试无需原生模块。
library;

import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';

import 'package:gstore/core/design/app_components.dart';
import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/design/app_sheet.dart';
import 'package:gstore/core/design/app_spacing.dart';
import 'package:gstore/core/design/app_typography.dart';
import 'package:gstore/core/rust/proxy/ProxyContract.dart';
import 'package:gstore/core/rust/proxy/ProxyModule.dart';

import 'proxy_diagnostics_facade.dart';

/// 日志级别过滤的「全部」哨兵值（`log.get` 不传 `level`）。
const String _kLogLevelAll = 'all';

/// 诊断页。
class ProxyDiagnosticsPage extends StatefulWidget {
  const ProxyDiagnosticsPage({super.key, this.facade});

  /// 诊断门面（测试可注入假实现；为空时用生产适配器）。
  final ProxyDiagnosticsFacade? facade;

  @override
  State<ProxyDiagnosticsPage> createState() => _ProxyDiagnosticsPageState();
}

class _ProxyDiagnosticsPageState extends State<ProxyDiagnosticsPage> {
  late final ProxyDiagnosticsFacade _facade;
  final TextEditingController _configProfile = TextEditingController();

  // Clash 回环控制器（仅诊断）。
  ClashApiStatus? _clashStatus;
  String? _clashError;
  bool _clashBusy = false;

  // 日志。
  LogPage? _logPage;
  String? _logError;
  bool _logBusy = false;
  String _logLevelFilter = _kLogLevelAll;

  // 规则。
  RulesSnapshot? _rules;
  String? _rulesError;
  bool _rulesBusy = false;

  // config 触发。
  GeneratedConfig? _configResult;
  String? _configError;
  bool _configBusy = false;

  @override
  void initState() {
    super.initState();
    _facade = widget.facade ?? ProxyModuleDiagnosticsFacade();
    _refreshClashStatus();
    _loadLogs();
    _loadRules();
  }

  @override
  void dispose() {
    _configProfile.dispose();
    super.dispose();
  }

  // ==================== Clash 回环控制器（仅诊断） ====================

  Future<void> _refreshClashStatus() async {
    try {
      final status = await _facade.clashApiStatus();
      if (!mounted) return;
      setState(() {
        _clashStatus = status;
        _clashError = null;
      });
    } on ProxyModuleException catch (error) {
      if (!mounted) return;
      setState(() => _clashError = error.message);
    } catch (error) {
      if (!mounted) return;
      setState(() => _clashError = '$error');
    }
  }

  Future<void> _startClashApi() async {
    if (_clashBusy) return;
    setState(() {
      _clashBusy = true;
      _clashError = null;
    });
    try {
      final status = await _facade.clashApiStart();
      if (!mounted) return;
      setState(() {
        _clashStatus = status;
        _clashBusy = false;
      });
      AppDialogs.showSuccess('诊断控制器已启用（仅用于诊断）');
    } on ProxyModuleException catch (error) {
      if (!mounted) return;
      final friendly = _friendlyClashError(error);
      setState(() {
        _clashError = friendly;
        _clashBusy = false;
      });
      AppDialogs.showError(friendly);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _clashError = '诊断控制器启动失败：$error';
        _clashBusy = false;
      });
      AppDialogs.showError('诊断控制器启动失败：$error');
    }
  }

  Future<void> _stopClashApi() async {
    if (_clashBusy) return;
    setState(() {
      _clashBusy = true;
      _clashError = null;
    });
    try {
      final result = await _facade.clashApiStop();
      if (!mounted) return;
      setState(() {
        _clashStatus = ClashApiStatus(
          enabled: result.enabled,
          bound: false,
        );
        _clashBusy = false;
      });
      AppDialogs.showSuccess(result.wasRunning ? '诊断控制器已停止' : '诊断控制器本就未运行');
    } on ProxyModuleException catch (error) {
      if (!mounted) return;
      setState(() {
        _clashError = error.message;
        _clashBusy = false;
      });
      AppDialogs.showError(error.message);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _clashError = '诊断控制器停止失败：$error';
        _clashBusy = false;
      });
      AppDialogs.showError('诊断控制器停止失败：$error');
    }
  }

  /// 把契约错误映射为**友好**文案；无隧道（`PROXY_NOT_CONFIGURED`）给出可操作
  /// 提示而非裸错误码。
  String _friendlyClashError(ProxyModuleException error) {
    switch (error.code) {
      case 'PROXY_NOT_CONFIGURED':
        return '诊断控制器需要隧道运行：请先连接网络，再启用诊断控制器。';
      case 'PROXY_CLASH_API_FAILED':
        return '诊断控制器启动失败（回环端口绑定失败）：${error.message}';
      default:
        return error.message;
    }
  }

  // ==================== 日志查看器 ====================

  Future<void> _loadLogs() async {
    setState(() {
      _logBusy = true;
      _logError = null;
    });
    try {
      final page = await _facade.logGet(
        LogGetRequest(
          limit: 200,
          level: _logLevelFilter == _kLogLevelAll ? null : _logLevelFilter,
        ),
      );
      if (!mounted) return;
      setState(() {
        _logPage = page;
        _logBusy = false;
      });
    } on ProxyModuleException catch (error) {
      if (!mounted) return;
      setState(() {
        _logError = error.message;
        _logBusy = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _logError = '日志读取失败：$error';
        _logBusy = false;
      });
    }
  }

  void _selectLogLevel(String level) {
    if (level == _logLevelFilter) return;
    setState(() => _logLevelFilter = level);
    _loadLogs();
  }

  Future<void> _clearLogs() async {
    final ok = await AppDialogs.showConfirmSheet(
      title: '清空日志',
      message: '将清空引擎日志环（游标继续前进），确定继续吗？',
      confirmText: '清空',
      isDangerous: true,
      icon: const Icon(TablerIcons.trash),
    );
    if (ok != true || !mounted) return;
    try {
      await _facade.logClear();
      if (!mounted) return;
      AppDialogs.showSuccess('日志已清空');
      await _loadLogs();
    } on ProxyModuleException catch (error) {
      if (!mounted) return;
      AppDialogs.showError(error.message, title: '清空失败');
    } catch (error) {
      if (!mounted) return;
      AppDialogs.showError('清空失败：$error');
    }
  }

  // ==================== 规则查看器 ====================

  Future<void> _loadRules() async {
    setState(() {
      _rulesBusy = true;
      _rulesError = null;
    });
    try {
      final rules = await _facade.rulesGet();
      if (!mounted) return;
      setState(() {
        _rules = rules;
        _rulesBusy = false;
      });
    } on ProxyModuleException catch (error) {
      if (!mounted) return;
      setState(() {
        _rulesError = error.message;
        _rulesBusy = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _rulesError = '规则读取失败：$error';
        _rulesBusy = false;
      });
    }
  }

  Future<void> _openRulesReloadSheet() async {
    if (_rulesBusy) return;
    final config = await AppSheet.showCustom<String>(
      context: context,
      builder: (sheetContext) => const _RulesReloadSheet(),
    );
    if (!mounted || config == null) return;
    final trimmed = config.trim();
    if (trimmed.isEmpty) {
      AppDialogs.showError('请粘贴内联 config 后再重新加载');
      return;
    }
    setState(() {
      _rulesBusy = true;
      _rulesError = null;
    });
    try {
      final rules = await _facade.rulesReload(
        RulesReloadRequest(config: trimmed),
      );
      if (!mounted) return;
      setState(() {
        _rules = rules;
        _rulesBusy = false;
      });
      AppDialogs.showSuccess('规则已重新加载');
    } on ProxyModuleException catch (error) {
      if (!mounted) return;
      setState(() {
        _rulesError = error.message;
        _rulesBusy = false;
      });
      AppDialogs.showError(error.message, title: '规则重载失败');
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _rulesError = '规则重载失败：$error';
        _rulesBusy = false;
      });
      AppDialogs.showError('规则重载失败：$error');
    }
  }

  // ==================== config 手动触发 ====================

  GenerateRequest _configRequest() {
    final profile = _configProfile.text.trim();
    return GenerateRequest(profileId: profile.isEmpty ? null : profile);
  }

  Future<void> _generateConfig() async {
    if (_configBusy) return;
    setState(() {
      _configBusy = true;
      _configError = null;
    });
    try {
      final generated = await _facade.configGenerate(_configRequest());
      if (!mounted) return;
      setState(() {
        _configResult = generated;
        _configBusy = false;
      });
      AppDialogs.showSuccess('配置已生成（仅展示摘要，正文已省略）');
    } on ProxyModuleException catch (error) {
      if (!mounted) return;
      setState(() {
        _configError = error.message;
        _configBusy = false;
      });
      AppDialogs.showError(error.message, title: '生成失败');
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _configError = '生成失败：$error';
        _configBusy = false;
      });
      AppDialogs.showError('生成失败：$error');
    }
  }

  Future<void> _applyConfig() async {
    if (_configBusy) return;
    setState(() {
      _configBusy = true;
      _configError = null;
    });
    try {
      final applied = await _facade.configApply(_configRequest());
      if (!mounted) return;
      setState(() {
        _configResult = applied;
        _configBusy = false;
      });
      AppDialogs.showSuccess('配置已应用到运行中的引擎');
    } on ProxyModuleException catch (error) {
      if (!mounted) return;
      setState(() {
        _configError = error.message;
        _configBusy = false;
      });
      AppDialogs.showError(error.message, title: '应用失败');
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _configError = '应用失败：$error';
        _configBusy = false;
      });
      AppDialogs.showError('应用失败：$error');
    }
  }

  // ==================== 构建 ====================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('诊断与日志'),
        actions: [
          IconButton(
            key: const Key('diagnostics_refresh_all'),
            tooltip: '刷新',
            icon: const Icon(TablerIcons.refresh),
            onPressed: () {
              _refreshClashStatus();
              _loadLogs();
              _loadRules();
            },
          ),
        ],
      ),
      body: ListView(
        padding: AppSpacing.allLG,
        children: [
          _buildClashApiCard(context),
          const SizedBox(height: AppSpacing.lg),
          _buildLogsCard(context),
          const SizedBox(height: AppSpacing.lg),
          _buildRulesCard(context),
          const SizedBox(height: AppSpacing.lg),
          _buildConfigCard(context),
        ],
      ),
    );
  }

  Widget _buildClashApiCard(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final status = _clashStatus;
    return _SectionCard(
      icon: TablerIcons.activity,
      title: 'Clash 诊断控制器',
      trailing:
          const _DiagnosticsOnlyBadge(key: Key('clash_diag_only_badge')),
      children: [
        Text(
          '启用 meow 内置的 mihomo 兼容回环控制器，仅供诊断 / 第三方面板排查使用。'
          '它默认关闭、只绑定 127.0.0.1，且需要隧道运行；正常业务绝不走该 HTTP API。',
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        _kv(
          theme,
          '状态',
          status == null ? '未知' : (status.enabled ? '已启用' : '未启用'),
        ),
        if (status != null && status.enabled) ...[
          _kv(theme, '监听地址', status.address ?? '—'),
          _kv(theme, '端口', status.port?.toString() ?? '—'),
          _kv(theme, '仅回环', status.isLoopbackOnly ? '是' : '否'),
        ],
        if (_clashError != null) ...[
          const SizedBox(height: AppSpacing.sm),
          Text(
            _clashError!,
            key: const Key('diagnostics_clash_error'),
            style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
          ),
        ],
        const SizedBox(height: AppSpacing.md),
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.sm,
          children: [
            FilledButton.tonalIcon(
              key: const Key('diagnostics_clash_start'),
              onPressed: _clashBusy ? null : _startClashApi,
              icon: const Icon(TablerIcons.player_play,
                  size: AppTypography.iconSM),
              label: const Text('启动（仅诊断）'),
            ),
            OutlinedButton.icon(
              key: const Key('diagnostics_clash_stop'),
              onPressed: _clashBusy ? null : _stopClashApi,
              icon: const Icon(TablerIcons.player_stop,
                  size: AppTypography.iconSM),
              label: const Text('停止'),
            ),
            TextButton.icon(
              key: const Key('diagnostics_clash_refresh'),
              onPressed: _clashBusy ? null : _refreshClashStatus,
              icon: const Icon(TablerIcons.refresh,
                  size: AppTypography.iconSM),
              label: const Text('刷新状态'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildLogsCard(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final page = _logPage;
    final records = page?.records ?? const <LogRecord>[];
    return _SectionCard(
      icon: TablerIcons.file_text,
      title: '日志查看器',
      trailing: page == null
          ? null
          : Text(
              '保留 ${page.retained}/${page.capacity}',
              key: const Key('diagnostics_log_retained'),
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: AppSegmentedButton<String>(
            key: const Key('diagnostics_log_level_selector'),
            value: _logLevelFilter,
            enabled: !_logBusy,
            density: AppSegmentedButton.mediumDensity,
            segments: const <AppSegment<String>>[
              AppSegment(
                value: _kLogLevelAll,
                label: '全部',
                key: Key('diagnostics_log_level_all'),
              ),
              AppSegment(
                value: 'debug',
                label: 'DEBUG',
                key: Key('diagnostics_log_level_debug'),
              ),
              AppSegment(
                value: 'info',
                label: 'INFO',
                key: Key('diagnostics_log_level_info'),
              ),
              AppSegment(
                value: 'warn',
                label: 'WARN',
                key: Key('diagnostics_log_level_warn'),
              ),
              AppSegment(
                value: 'error',
                label: 'ERROR',
                key: Key('diagnostics_log_level_error'),
              ),
            ],
            onChanged: _selectLogLevel,
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        Row(
          children: [
            FilledButton.tonalIcon(
              key: const Key('diagnostics_log_refresh'),
              onPressed: _logBusy ? null : _loadLogs,
              icon: const Icon(TablerIcons.refresh,
                  size: AppTypography.iconSM),
              label: const Text('刷新'),
            ),
            const SizedBox(width: AppSpacing.sm),
            TextButton.icon(
              key: const Key('diagnostics_log_clear'),
              onPressed: _logBusy ? null : _clearLogs,
              icon: Icon(TablerIcons.trash,
                  size: AppTypography.iconSM, color: scheme.error),
              label: Text('清空日志', style: TextStyle(color: scheme.error)),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        if (_logError != null)
          Text(
            _logError!,
            style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
          )
        else if (_logBusy && page == null)
          const Center(child: AppLoading(size: AppLoadingSize.small))
        else if (records.isEmpty)
          Padding(
            padding: AppSpacing.onlyVerticalLG,
            child: Center(
              child: Text(
                '暂无日志',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          )
        else
          for (final record in records)
            _LogRecordTile(
              key: ValueKey<String>('diagnostics_log_record_${record.cursor}'),
              record: record,
            ),
      ],
    );
  }

  Widget _buildRulesCard(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final snapshot = _rules;
    final rules = snapshot?.rules ?? const <RuleLine>[];
    return _SectionCard(
      icon: TablerIcons.list_check,
      title: '规则查看器',
      trailing: snapshot == null
          ? null
          : Text(
              '共 ${snapshot.count} 条 · rev ${snapshot.revision}',
              key: const Key('diagnostics_rules_summary'),
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
      children: [
        if (snapshot != null)
          _kv(theme, '最终规则', snapshot.finalTarget.isEmpty ? 'DIRECT' : snapshot.finalTarget),
        if (snapshot != null && snapshot.errors.isNotEmpty)
          _kv(theme, '解析错误', '${snapshot.errors.length} 条'),
        const SizedBox(height: AppSpacing.sm),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.tonalIcon(
            key: const Key('diagnostics_rules_reload'),
            onPressed: _rulesBusy ? null : _openRulesReloadSheet,
            icon: const Icon(TablerIcons.reload, size: AppTypography.iconSM),
            label: const Text('重新加载规则'),
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        if (_rulesError != null)
          Text(
            _rulesError!,
            style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
          )
        else if (_rulesBusy && snapshot == null)
          const Center(child: AppLoading(size: AppLoadingSize.small))
        else if (rules.isEmpty)
          Padding(
            padding: AppSpacing.onlyVerticalLG,
            child: Center(
              child: Text(
                '暂无规则',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          )
        else
          for (final rule in rules)
            _RuleTile(
              key: ValueKey<String>('diagnostics_rule_${rule.index}'),
              rule: rule,
            ),
      ],
    );
  }

  Widget _buildConfigCard(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final result = _configResult;
    return _SectionCard(
      icon: TablerIcons.settings_cog,
      title: '配置生成 / 应用',
      trailing:
          const _DiagnosticsOnlyBadge(key: Key('config_diag_only_badge')),
      children: [
        Text(
          '手动触发 `config.generate`（渲染受控模板）或 `config.apply`（热应用到'
          '运行中引擎）。生成结果可能含代理凭证，因此**只展示摘要，绝不渲染正文**。',
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        TextField(
          key: const Key('diagnostics_config_profile'),
          controller: _configProfile,
          enabled: !_configBusy,
          decoration: const InputDecoration(
            labelText: '订阅 id（可选）',
            hintText: '留空 = 使用当前配置',
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.sm,
          children: [
            FilledButton.tonalIcon(
              key: const Key('diagnostics_config_generate'),
              onPressed: _configBusy ? null : _generateConfig,
              icon: const Icon(TablerIcons.file_code,
                  size: AppTypography.iconSM),
              label: const Text('生成配置'),
            ),
            OutlinedButton.icon(
              key: const Key('diagnostics_config_apply'),
              onPressed: _configBusy ? null : _applyConfig,
              icon: const Icon(TablerIcons.rocket,
                  size: AppTypography.iconSM),
              label: const Text('应用配置'),
            ),
          ],
        ),
        if (_configError != null) ...[
          const SizedBox(height: AppSpacing.sm),
          Text(
            _configError!,
            style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
          ),
        ],
        if (result != null) ...[
          const SizedBox(height: AppSpacing.md),
          Container(
            key: const Key('diagnostics_config_result'),
            width: double.infinity,
            padding: AppSpacing.allMD,
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(AppSpacing.sm),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _kv(theme, '格式', result.format.isEmpty ? '—' : result.format),
                _kv(theme, '模板', result.template.isEmpty ? '—' : result.template),
                if (result.profileId != null)
                  _kv(theme, '订阅 id', result.profileId!),
                _kv(theme, 'hash', result.hash.isEmpty ? '—' : result.hash),
                _kv(
                  theme,
                  '计数',
                  '代理 ${result.counts.proxies} · 组 ${result.counts.groups}'
                      ' · 规则 ${result.counts.rules}',
                ),
                if (result.applied == true)
                  _kv(theme, '应用', '已应用（规则 ${result.rulesCount ?? 0} 条）'),
                if (result.warnings.isNotEmpty)
                  _kv(theme, '警告', '${result.warnings.length} 条'),
                const SizedBox(height: AppSpacing.sm),
                Text(
                  '配置正文已省略（可能含代理凭证，仅展示摘要）。',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _kv(ThemeData theme, String label, String value) {
    return Padding(
      padding: AppSpacing.onlyVerticalXS,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: theme.textTheme.bodySmall),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

// ==================== 展示组件 ====================

/// 规则重载弹层：自持 [TextEditingController] 并在自身 `dispose` 释放，
/// 避免外层在弹层退出动画期间提前释放控制器。
class _RulesReloadSheet extends StatefulWidget {
  const _RulesReloadSheet();

  @override
  State<_RulesReloadSheet> createState() => _RulesReloadSheetState();
}

class _RulesReloadSheetState extends State<_RulesReloadSheet> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AppSheetScaffold(
      title: '重新加载规则',
      subtitle: '粘贴内联 Clash config（`rules:` 段）；留空则取消。',
      icon: const Icon(TablerIcons.file_code),
      content: TextField(
        key: const Key('diagnostics_rules_config_field'),
        controller: _controller,
        maxLines: 6,
        minLines: 3,
        decoration: const InputDecoration(
          labelText: '内联 config',
          hintText: 'rules:\n  - MATCH,DIRECT',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('diagnostics_rules_reload_confirm'),
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: const Text('重新加载'),
        ),
      ],
    );
  }
}

/// 「仅用于诊断」徽标：主题令牌着色，避免误把该能力当正常业务。
class _DiagnosticsOnlyBadge extends StatelessWidget {  const _DiagnosticsOnlyBadge({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(AppSpacing.sm),
      ),
      child: Text(
        '仅用于诊断',
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: scheme.onTertiaryContainer,
            ),
      ),
    );
  }
}

/// 单条日志：级别徽标 + 消息 + 游标。
class _LogRecordTile extends StatelessWidget {
  const _LogRecordTile({super.key, required this.record});

  final LogRecord record;

  Color _levelColor(ColorScheme scheme) {
    switch (record.level) {
      case ProxyLogLevel.debug:
        return scheme.onSurfaceVariant;
      case ProxyLogLevel.info:
        return scheme.primary;
      case ProxyLogLevel.warn:
        return scheme.tertiary;
      case ProxyLogLevel.error:
        return scheme.error;
      case ProxyLogLevel.unknown:
        return scheme.onSurfaceVariant;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final message = record.message.isEmpty
        ? (record.connection?.domain ?? record.dns?.domain ?? '(空)')
        : record.message;
    return Padding(
      padding: AppSpacing.onlyVerticalXS,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.xs,
              vertical: 2,
            ),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(AppSpacing.xs),
            ),
            child: Text(
              record.level.wire.toUpperCase(),
              style: theme.textTheme.labelSmall?.copyWith(
                color: _levelColor(scheme),
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              message,
              style: theme.textTheme.bodySmall,
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Text(
            '#${record.cursor}',
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// 单条规则：类型 / 值 → 目标。
class _RuleTile extends StatelessWidget {
  const _RuleTile({super.key, required this.rule});

  final RuleLine rule;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final value = rule.value.isEmpty ? '(无值)' : rule.value;
    return Padding(
      padding: AppSpacing.onlyVerticalXS,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '#${rule.index}',
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(rule.type, style: theme.textTheme.bodySmall),
                Text(
                  value,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                Text(
                  '→ ${rule.target}',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 通用小节卡片（与设置页视觉一致；本页私有，不改动共享组件）。
class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.icon,
    required this.title,
    required this.children,
    this.trailing,
  });

  final IconData icon;
  final String title;
  final List<Widget> children;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: AppSpacing.allLG,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon,
                    size: AppTypography.iconMD,
                    color: theme.colorScheme.primary),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(title, style: theme.textTheme.titleSmall),
                ),
                if (trailing != null)
                  LayoutBuilder(
                    builder: (context, constraints) => ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: constraints.maxWidth * 0.7,
                      ),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerRight,
                        child: trailing!,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            ...children,
          ],
        ),
      ),
    );
  }
}
