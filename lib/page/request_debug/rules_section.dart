/// 「请求调试」改写规则分区（plan todo 34）。
///
/// 规则是 **Rust 引擎的全局能力**（非单请求私有），仅作用于 h1/h2 请求；
/// 本分区经门面 Seam 2（[RequestDebugFacade.getCaptureRules] /
/// [RequestDebugFacade.setCaptureRule] / [RequestDebugFacade.removeCaptureRule]）
/// 读写 `capture.rules.*` 契约，**不**直接触碰 FFI。
///
/// 能力：
/// - 列表来自 `capture.rules.get`（URL / 方法 / 类型 / 开关 / 命中数）；
/// - `+` 新建规则；点击行编辑；快捷开关（默认关）；
/// - 编辑器：精确 URL（+ 可选方法）、类型 `替换响应`（状态 / 头 / Body）
///   或 `返回本地响应`、启用开关（**默认关**）、备注；
/// - 保存 / 删除分别走 [RequestDebugFacade.setCaptureRule] /
///   [RequestDebugFacade.removeCaptureRule]；删除经危险二次确认。
///
/// **WS 改写不支持**：规则仅作用于 h1/h2 请求，WebSocket 帧仅捕获不改写；
/// UI 顶部固定标注该事实（[debugRewriteKindLabel] / 备注文案）。
///
/// 设计约束：颜色 / 字号全取主题令牌（[Theme.of]），弹层走统一底部弹层
/// （[AppSheet] / [AppDialogs]），零硬编码颜色 / 字号。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';

import 'package:gstore/core/design/app_components.dart';
import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/design/app_radius.dart';
import 'package:gstore/core/design/app_sheet.dart';
import 'package:gstore/core/design/app_spacing.dart';
import 'package:gstore/core/design/app_typography.dart';
import 'package:gstore/core/request_debug/request_debug.dart';
import 'package:gstore/core/rust/proxy/ProxyContract.dart';
import 'package:gstore/page/proxy/proxy_capture_bridge.dart';

import 'import_export_actions.dart';
import 'search_sort_bar.dart';

// ==================== 映射 / 展示辅助 ====================

/// 改写类型的中文展示名。
String debugRewriteKindLabel(DebugRewriteKind kind) => switch (kind) {
      DebugRewriteKind.replaceResponse => '替换响应',
      DebugRewriteKind.localResponse => '返回本地响应',
    };

/// Rust `CaptureRule.kind` 线缆值（`API.md` §2.19）：`replace` / `local`。
String debugRewriteKindWire(DebugRewriteKind kind) => switch (kind) {
      DebugRewriteKind.replaceResponse => 'replace',
      DebugRewriteKind.localResponse => 'local',
    };

/// 改写规则 URL 匹配方式的中文展示名。
String debugRewriteMatchLabel(DebugRewriteMatch match) => switch (match) {
      DebugRewriteMatch.exact => '精确',
      DebugRewriteMatch.prefix => '前缀',
      DebugRewriteMatch.glob => '通配',
      DebugRewriteMatch.regex => '正则',
    };

/// 校验规则 URL 模式（best-effort；Rust 侧为权威，非法仍有 422 兜底）。
///
/// 返回 `null` 表示通过，否则为面向用户的错误文案。
String? validateRulePattern(DebugRewriteMatch match, String url) {
  final lower = url.toLowerCase();
  final isHttp = lower.startsWith('http://') || lower.startsWith('https://');
  switch (match) {
    case DebugRewriteMatch.exact:
    case DebugRewriteMatch.prefix:
      return isHttp ? null : 'URL 必须是绝对 http(s) 地址';
    case DebugRewriteMatch.glob:
      return isHttp ? null : '通配 URL 必须以 http:// 或 https:// 开头';
    case DebugRewriteMatch.regex:
      try {
        RegExp(url);
        return null;
      } on FormatException catch (e) {
        return '正则表达式无效：${e.message}';
      }
  }
}

/// 把 UI 规则模型映射为 `capture.rules.set` 请求载荷。
///
/// **默认关**：[DebugRewriteRule.enabled] 缺省即为 `false`，此处原样下发，
/// 不隐式开启。无 id（新建）时省略 `id`，由 Rust 铸造。
///
/// 供生产适配器（plan todo 35）在端口实现里复用；本分区测试据此断言
/// `capture.rules.set` 的**精确**载荷（含 `enabled:false` 默认与 kind 映射）。
CaptureRuleSetRequest debugRuleToSetRequest(DebugRewriteRule rule) {
  final headers = rule.respHeaders
      ?.where((h) => h.enabled && h.name.isNotEmpty)
      .map((h) => '${h.name}: ${h.value}')
      .toList();
  final body = rule.respBody;
  final method = rule.method;
  final remark = rule.remark;
  return CaptureRuleSetRequest(
    id: rule.id.isEmpty ? null : rule.id,
    enabled: rule.enabled,
    method: (method == null || method.isEmpty) ? null : method,
    url: rule.url,
    kind: debugRewriteKindWire(rule.kind),
    statusCode: rule.statusCode,
    headers:
        (headers == null || headers.isEmpty) ? null : headers.join('\n'),
    body: (body == null || body.isEmpty) ? null : body,
    remark: (remark == null || remark.isEmpty) ? null : remark,
    delayMs: rule.delayMs == 0 ? null : rule.delayMs,
    matchType:
        rule.matchType == DebugRewriteMatch.exact ? null : rule.matchType.wire,
  );
}

/// 解析多行 `name: value` 响应头文本（忽略空行 / 无冒号行）。
List<DebugHeader> parseRuleHeaderLines(String text) {
  final out = <DebugHeader>[];
  for (final line in text.split('\n')) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) continue;
    final idx = trimmed.indexOf(':');
    if (idx <= 0) continue;
    out.add(DebugHeader(
      name: trimmed.substring(0, idx).trim(),
      value: trimmed.substring(idx + 1).trim(),
    ));
  }
  return out;
}

/// 由抓包改写规则预填派生**新建**规则种子（id 空 = 新建）。
///
/// 映射 method/url + 当前响应（状态码 / 头 / Body）为 `替换响应` 初值；
/// `enabled` 保持默认关，**不**隐式开启。供「请求调试」页消费路由 extra 后
/// 打开预填编辑器（plan todo 7）。
DebugRewriteRule debugRewriteRuleFromPrefill(CaptureRulePrefill prefill) {
  final headers = prefill.responseHeaders;
  return DebugRewriteRule(
    id: '',
    method: prefill.method.isEmpty ? null : prefill.method,
    url: prefill.url,
    kind: DebugRewriteKind.replaceResponse,
    statusCode: prefill.statusCode,
    respHeaders: (headers == null || headers.isEmpty)
        ? null
        : parseRuleHeaderLines(headers),
    respBody: prefill.replaceBody.isEmpty ? null : prefill.replaceBody,
  );
}

// ==================== 分区组件 ====================

/// 改写规则分区：列表 + 新建 / 编辑 / 开关 / 删除。
class RequestDebugRulesSection extends StatefulWidget {
  const RequestDebugRulesSection({
    super.key,
    required this.facade,
    this.prefill,
    this.saveFile,
  });

  /// 窄门面（Seam 2：`capture.rules.*`）。
  final RequestDebugFacade facade;

  /// 抓包透传的改写规则预填（plan todo 7）。
  ///
  /// 非空时在首帧后自动打开**新建**规则编辑器并预填其字段；`null`（默认入口）
  /// 行为不变，不弹任何编辑器。
  final CaptureRulePrefill? prefill;

  /// 导出文件保存接缝（测试注入；为空时走 [FilePicker]）。
  final DebugSaveFile? saveFile;

  @override
  State<RequestDebugRulesSection> createState() =>
      _RequestDebugRulesSectionState();
}

class _RequestDebugRulesSectionState extends State<RequestDebugRulesSection> {
  List<DebugRewriteRule> _rules = const <DebugRewriteRule>[];
  bool _loading = true;
  String? _loadError;

  /// 正在保存（快捷开关）的规则 id，避免重复点击。
  final Set<String> _busy = <String>{};

  /// 搜索查询串（空 = 不过滤）。
  final TextEditingController _searchCtrl = TextEditingController();
  String _query = '';

  /// 排序顺序（默认原序）。
  DebugSortOrder _sort = DebugSortOrder.original;

  RequestDebugFacade get _facade => widget.facade;

  @override
  void initState() {
    super.initState();
    unawaited(_loadRules());
    final prefill = widget.prefill;
    if (prefill != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        unawaited(_openPrefilled(debugRewriteRuleFromPrefill(prefill)));
      });
    }
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadRules({bool silent = false}) async {
    if (!silent) {
      setState(() {
        _loading = true;
        _loadError = null;
      });
    }
    final result = await _facade.getCaptureRules();
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (result.isSuccess) {
        _rules = result.value ?? const <DebugRewriteRule>[];
        _loadError = null;
      } else {
        _loadError = result.error;
      }
    });
    if (result.isFailure) {
      AppDialogs.showError('规则加载失败：${result.error}');
    }
  }

  // ==================== 动作 ====================

  Future<void> _create() async {
    final created = await AppSheet.showCustom<DebugRewriteRule>(
      context: context,
      builder: (_) => const _RuleEditorSheet(rule: null),
    );
    if (created == null || !mounted) return;
    await _save(created, successMessage: '规则已创建');
  }

  /// 打开抓包预填的**新建**规则编辑器（plan todo 7）。
  ///
  /// 仅预填字段，保存仍由用户在编辑器内确认；`enabled` 保持默认关。
  Future<void> _openPrefilled(DebugRewriteRule seed) async {
    final created = await AppSheet.showCustom<DebugRewriteRule>(
      context: context,
      builder: (_) => _RuleEditorSheet(rule: null, seed: seed),
    );
    if (created == null || !mounted) return;
    await _save(created, successMessage: '规则已创建');
  }

  Future<void> _edit(DebugRewriteRule rule) async {
    final edited = await AppSheet.showCustom<DebugRewriteRule>(
      context: context,
      builder: (_) => _RuleEditorSheet(rule: rule),
    );
    if (edited == null || !mounted) return;
    await _save(edited, successMessage: '规则已保存');
  }

  /// 保存（新建 / 编辑共用）：门面失败 → `showError`，绝不崩。
  Future<void> _save(
    DebugRewriteRule rule, {
    required String successMessage,
  }) async {
    final result = await _facade.setCaptureRule(rule);
    if (!mounted) return;
    if (result.isFailure) {
      AppDialogs.showError('规则保存失败：${result.error}');
      return;
    }
    AppDialogs.showSuccess(successMessage);
    await _loadRules(silent: true);
  }

  /// 快捷开关：默认关；切换即经门面 upsert。
  Future<void> _toggle(DebugRewriteRule rule, bool value) async {
    if (_busy.contains(rule.id)) return;
    setState(() => _busy.add(rule.id));
    final result = await _facade.setCaptureRule(rule.copyWith(enabled: value));
    if (!mounted) return;
    setState(() => _busy.remove(rule.id));
    if (result.isFailure) {
      AppDialogs.showError('规则保存失败：${result.error}');
      return;
    }
    await _loadRules(silent: true);
  }

  Future<void> _delete(DebugRewriteRule rule) async {
    final ok = await AppDialogs.showConfirmSheet(
      title: '删除改写规则',
      message: '将删除规则「${rule.url}」，此操作无法撤销。',
      confirmText: '删除',
      isDangerous: true,
    );
    if (ok != true || !mounted) return;
    final result = await _facade.removeCaptureRule(rule.id);
    if (!mounted) return;
    if (result.isFailure) {
      AppDialogs.showError('规则删除失败：${result.error}');
      return;
    }
    await _loadRules(silent: true);
  }

  /// 把当前规则导出为 JSON 文件。
  Future<void> _exportRules() =>
      exportDebugRules(context, _rules, saveFile: widget.saveFile);

  // ==================== 构建 ====================

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildHeader(context),
        const Divider(height: 1),
        Expanded(child: _buildBody(context)),
      ],
    );
  }

  Widget _buildHeader(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.sm,
        AppSpacing.sm,
        AppSpacing.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text('改写规则', style: theme.textTheme.titleMedium),
              ),
              IconButton(
                key: const Key('request-debug-rules-refresh'),
                tooltip: '刷新',
                icon: const Icon(TablerIcons.refresh),
                onPressed: () => _loadRules(),
              ),
              IconButton(
                key: const Key('request-debug-rules-export'),
                tooltip: '导出规则 JSON',
                icon: const Icon(TablerIcons.file_download),
                onPressed: _exportRules,
              ),
              IconButton(
                key: const Key('request-debug-rules-add'),
                tooltip: '新建规则',
                icon: const Icon(TablerIcons.plus),
                onPressed: _create,
              ),
            ],
          ),
          DebugSearchSortBar(
            sectionId: 'request-debug-rules',
            hint: '搜索规则 URL / 方法 / 备注',
            controller: _searchCtrl,
            query: _query,
            sort: _sort,
            onQueryChanged: (value) => setState(() => _query = value),
            onSortChanged: (value) => setState(() => _sort = value),
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg,
              0,
              AppSpacing.sm,
              AppSpacing.sm,
            ),
          ),
          Container(
            padding: AppSpacing.allSM,
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: AppRadius.allSM,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '规则为全局引擎能力：对所有匹配请求生效，非单请求私有；新建默认关闭。',
                  key: const Key('request-debug-rules-global-note'),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  '仅作用于 HTTP/1.1、HTTP/2 请求；WebSocket（WS）帧仅捕获不改写，不支持 WS 改写。',
                  key: const Key('request-debug-rules-ws-note'),
                  style: theme.textTheme.bodySmall?.copyWith(
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

  Widget _buildBody(BuildContext context) {
    if (_loading) {
      return const Center(child: AppLoading(size: AppLoadingSize.medium));
    }
    if (_loadError != null) {
      return _buildLoadError(context);
    }
    if (_rules.isEmpty) {
      return _buildEmpty(context);
    }
    // 过滤 + 排序为纯函数，不改动规则端口 / CRUD 语义。
    final displayed = sortDebugRules(
      filterDebugRules(_rules, _query),
      _sort,
    );
    if (displayed.isEmpty) {
      return _buildSearchEmpty(context);
    }
    return ListView.builder(
      padding: AppSpacing.onlyVerticalSM,
      itemCount: displayed.length,
      itemBuilder: (context, index) => _buildRule(context, displayed[index]),
    );
  }

  Widget _buildRule(BuildContext context, DebugRewriteRule rule) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final method = rule.method ?? '任意方法';
    final enabledColor =
        rule.enabled ? scheme.primary : scheme.onSurfaceVariant;
    return ListTile(
      key: Key('request-debug-rule-${rule.id}'),
      leading: Switch(
        key: Key('request-debug-rule-toggle-${rule.id}'),
        value: rule.enabled,
        onChanged:
            _busy.contains(rule.id) ? null : (value) => _toggle(rule, value),
      ),
      title: Text(
        rule.url,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        '$method · ${debugRewriteKindLabel(rule.kind)} · '
        '${debugRewriteMatchLabel(rule.matchType)} · '
        '${rule.enabled ? '已启用' : '未启用'} · 命中 ${rule.hitCount}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall?.copyWith(color: enabledColor),
      ),
      onTap: () => _edit(rule),
      trailing: PopupMenuButton<String>(
        key: Key('request-debug-rule-menu-${rule.id}'),
        icon: const Icon(TablerIcons.dots),
        onSelected: (value) {
          switch (value) {
            case 'edit':
              _edit(rule);
            case 'delete':
              _delete(rule);
          }
        },
        itemBuilder: (_) => [
          PopupMenuItem<String>(
            key: Key('request-debug-rule-edit-${rule.id}'),
            value: 'edit',
            child: const Text('编辑'),
          ),
          PopupMenuItem<String>(
            key: Key('request-debug-rule-delete-${rule.id}'),
            value: 'delete',
            child: const Text('删除'),
          ),
        ],
      ),
    );
  }

  Widget _buildLoadError(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Center(
      child: Padding(
        padding: AppSpacing.allXL,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ColoredAliIcon(
              icon: TablerIcons.alert_triangle,
              size: AppTypography.iconXXXL,
              color: scheme.error,
            ),
            const SizedBox(height: AppSpacing.md),
            Text('规则加载失败', style: theme.textTheme.titleMedium),
            const SizedBox(height: AppSpacing.sm),
            Text(
              _loadError!,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            FilledButton(
              key: const Key('request-debug-rules-retry'),
              onPressed: () => _loadRules(),
              child: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSearchEmpty(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Center(
      key: const Key('request-debug-rules-search-empty'),
      child: Padding(
        padding: AppSpacing.allXL,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ColoredAliIcon(
              icon: TablerIcons.search_off,
              size: AppTypography.iconXXXL,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(height: AppSpacing.md),
            Text('未找到匹配的规则', style: theme.textTheme.titleMedium),
            const SizedBox(height: AppSpacing.sm),
            Text(
              '试试其他关键字，或清空搜索查看全部。',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmpty(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Center(
      child: Padding(
        padding: AppSpacing.allXL,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ColoredAliIcon(
              icon: TablerIcons.replace,
              size: AppTypography.iconXXXL,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(height: AppSpacing.md),
            Text('暂无改写规则', style: theme.textTheme.titleMedium),
            const SizedBox(height: AppSpacing.sm),
            Text(
              '新建规则以替换匹配请求的响应或返回本地响应。',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ==================== 规则编辑器 ====================

/// 规则编辑器弹层：精确 URL、可选方法、类型、开关（默认关）、备注。
class _RuleEditorSheet extends StatefulWidget {
  const _RuleEditorSheet({required this.rule, this.seed});

  /// 待编辑规则；`null` = 新建。
  final DebugRewriteRule? rule;

  /// 新建时的预填种子（`rule == null` 时生效）；`null` = 空表单。
  ///
  /// 与 [rule] 的区别：种子不携带既有 id，标题仍为「新建改写规则」，保存
  /// 走新建路径（由 Rust 铸造 id）。用于抓包「创建改写规则」透传（todo 7）。
  final DebugRewriteRule? seed;

  @override
  State<_RuleEditorSheet> createState() => _RuleEditorSheetState();
}

class _RuleEditorSheetState extends State<_RuleEditorSheet> {
  late final TextEditingController _url;
  late final TextEditingController _method;
  late final TextEditingController _status;
  late final TextEditingController _headers;
  late final TextEditingController _body;
  late final TextEditingController _remark;
  late final TextEditingController _delay;

  late DebugRewriteKind _kind;
  late DebugRewriteMatch _matchType;

  /// 启用开关（**默认关**）。
  late bool _enabled;

  @override
  void initState() {
    super.initState();
    // 预填种子：编辑既有规则时用 `rule`，否则用 `seed`（新建预填）。
    final rule = widget.rule ?? widget.seed;
    _url = TextEditingController(text: rule?.url ?? '');
    _method = TextEditingController(text: rule?.method ?? '');
    _status = TextEditingController(text: rule?.statusCode?.toString() ?? '');
    _headers = TextEditingController(
      text: rule?.respHeaders
              ?.map((h) => '${h.name}: ${h.value}')
              .join('\n') ??
          '',
    );
    _body = TextEditingController(text: rule?.respBody ?? '');
    _remark = TextEditingController(text: rule?.remark ?? '');
    _delay = TextEditingController(
      text: (rule?.delayMs ?? 0) == 0 ? '' : '${rule!.delayMs}',
    );
    _kind = rule?.kind ?? DebugRewriteKind.replaceResponse;
    _matchType = rule?.matchType ?? DebugRewriteMatch.exact;
    _enabled = rule?.enabled ?? false;
  }

  @override
  void dispose() {
    _url.dispose();
    _method.dispose();
    _status.dispose();
    _headers.dispose();
    _body.dispose();
    _remark.dispose();
    _delay.dispose();
    super.dispose();
  }

  void _save() {
    final url = _url.text.trim();
    if (url.isEmpty) {
      AppDialogs.showError('URL 不能为空');
      return;
    }
    final patternError = validateRulePattern(_matchType, url);
    if (patternError != null) {
      AppDialogs.showError(patternError);
      return;
    }
    final method = _method.text.trim();
    final remark = _remark.text.trim();
    final delayText = _delay.text.trim();
    final delay = delayText.isEmpty ? 0 : int.tryParse(delayText);
    if (delay == null || delay < 0) {
      AppDialogs.showError('延迟毫秒必须是非负整数');
      return;
    }
    final isReplace = _kind == DebugRewriteKind.replaceResponse;
    final status = int.tryParse(_status.text.trim());
    final headersText = _headers.text.trim();
    final body = _body.text;
    Navigator.of(context).pop(DebugRewriteRule(
      id: widget.rule?.id ?? '',
      enabled: _enabled,
      method: method.isEmpty ? null : method,
      url: url,
      kind: _kind,
      remark: remark.isEmpty ? null : remark,
      statusCode: isReplace ? status : null,
      respHeaders: isReplace && headersText.isNotEmpty
          ? parseRuleHeaderLines(headersText)
          : null,
      respBody: isReplace && body.isNotEmpty ? body : null,
      delayMs: delay,
      matchType: _matchType,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AppSheetScaffold(
      title: widget.rule == null ? '新建改写规则' : '编辑改写规则',
      subtitle: '规则为全局引擎能力；仅作用于 h1/h2 请求',
      icon: const ColoredAliIcon(icon: TablerIcons.replace),
      contentPadding: AppSpacing.onlyHorizontalXL,
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'WebSocket 帧仅捕获不改写，不支持 WS 改写。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          Text('匹配方式', style: theme.textTheme.titleSmall),
          const SizedBox(height: AppSpacing.sm),
          AppSegmentedButton<DebugRewriteMatch>(
            value: _matchType,
            density: AppSegmentedButton.mediumDensity,
            segments: const <AppSegment<DebugRewriteMatch>>[
              AppSegment(
                value: DebugRewriteMatch.exact,
                label: '精确',
                key: Key('request-debug-rule-match-exact'),
              ),
              AppSegment(
                value: DebugRewriteMatch.prefix,
                label: '前缀',
                key: Key('request-debug-rule-match-prefix'),
              ),
              AppSegment(
                value: DebugRewriteMatch.glob,
                label: '通配',
                key: Key('request-debug-rule-match-glob'),
              ),
              AppSegment(
                value: DebugRewriteMatch.regex,
                label: '正则',
                key: Key('request-debug-rule-match-regex'),
              ),
            ],
            onChanged: (value) => setState(() => _matchType = value),
          ),
          const SizedBox(height: AppSpacing.md),
          TextField(
            key: const Key('request-debug-rule-url'),
            controller: _url,
            decoration: InputDecoration(
              labelText: switch (_matchType) {
                DebugRewriteMatch.exact => '精确 URL（绝对 http/https）',
                DebugRewriteMatch.prefix => 'URL 前缀（绝对 http/https）',
                DebugRewriteMatch.glob => 'URL 通配（* 任意、? 单字符）',
                DebugRewriteMatch.regex => 'URL 正则（Rust regex）',
              },
              hintText: switch (_matchType) {
                DebugRewriteMatch.exact => 'https://api.example/path',
                DebugRewriteMatch.prefix => 'https://api.example/v1/',
                DebugRewriteMatch.glob => 'https://api.example/*/end',
                DebugRewriteMatch.regex => r'^https://api\.example/\d+$',
              },
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          TextField(
            key: const Key('request-debug-rule-method'),
            controller: _method,
            textCapitalization: TextCapitalization.characters,
            decoration: const InputDecoration(
              labelText: '方法（可选，留空 = 不限）',
              hintText: 'GET / POST …',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          Text('类型', style: theme.textTheme.titleSmall),
          const SizedBox(height: AppSpacing.sm),
          AppSegmentedButton<DebugRewriteKind>(
            value: _kind,
            density: AppSegmentedButton.mediumDensity,
            segments: const <AppSegment<DebugRewriteKind>>[
              AppSegment(
                value: DebugRewriteKind.replaceResponse,
                label: '替换响应',
                key: Key('request-debug-rule-kind-replace'),
              ),
              AppSegment(
                value: DebugRewriteKind.localResponse,
                label: '返回本地响应',
                key: Key('request-debug-rule-kind-local'),
              ),
            ],
            onChanged: (kind) => setState(() => _kind = kind),
          ),
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: [
              Expanded(
                child: Text('启用（默认关闭）', style: theme.textTheme.bodyLarge),
              ),
              Switch(
                key: const Key('request-debug-rule-enabled'),
                value: _enabled,
                onChanged: (value) => setState(() => _enabled = value),
              ),
            ],
          ),
          if (_kind == DebugRewriteKind.replaceResponse) ...[
            const SizedBox(height: AppSpacing.sm),
            TextField(
              key: const Key('request-debug-rule-status'),
              controller: _status,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: '状态码（可选）',
                hintText: '200',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            TextField(
              key: const Key('request-debug-rule-headers'),
              controller: _headers,
              minLines: 2,
              maxLines: 4,
              decoration: const InputDecoration(
                labelText: '响应头（可选，每行 name: value）',
                hintText: 'content-type: application/json',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            TextField(
              key: const Key('request-debug-rule-body'),
              controller: _body,
              minLines: 2,
              maxLines: 5,
              decoration: const InputDecoration(
                labelText: '响应 Body（可选）',
                border: OutlineInputBorder(),
              ),
            ),
          ],
          const SizedBox(height: AppSpacing.md),
          TextField(
            key: const Key('request-debug-rule-delay'),
            controller: _delay,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: '延迟毫秒（可选，0 = 不延迟）',
              hintText: '0',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          TextField(
            key: const Key('request-debug-rule-remark'),
            controller: _remark,
            decoration: const InputDecoration(
              labelText: '备注（可选）',
              border: OutlineInputBorder(),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('request-debug-rule-save'),
          onPressed: _save,
          child: const Text('保存'),
        ),
      ],
    );
  }
}
