/// 「请求调试」全屏请求编辑器（plan todo 31）。
///
/// 结构：
/// - 顶部：`Method 下拉 + URL + 发送`；
/// - 分段：`参数 / 头 / 体 / 认证 / Cookie / 响应`（复用 [AppSegmentedButton]）；
/// - 环境变量：URL 预览高亮（已定义解析、未定义红色标记）与「插入变量」；
/// - 底部动作：`发送 / 保存 / 另存为 / 导出 cURL`；
/// - 未保存离开经 [AppDialogs.showConfirmSheet] 二次确认，绝不静默丢弃编辑。
///
/// 设计约束：颜色 / 字号全取主题令牌（[Theme.of]），弹层走统一底部弹层 /
/// 统一骨架（[AppSheet] / [AppDialogs]），零硬编码颜色。
library;

import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';

import 'package:gstore/core/design/app_components.dart';
import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/design/app_radius.dart';
import 'package:gstore/core/design/app_sheet.dart';
import 'package:gstore/core/design/app_spacing.dart';
import 'package:gstore/core/design/app_typography.dart';
import 'package:gstore/core/request_debug/request_debug.dart';

import 'response_viewer.dart';

/// 编辑器分段。
enum RequestEditorSegment {
  params,
  headers,
  body,
  auth,
  cookies,
  response,
}

/// 全屏请求编辑器页。
class RequestEditorPage extends StatefulWidget {
  const RequestEditorPage({
    super.key,
    required this.facade,
    this.collectionId,
    this.request,
  });

  /// 窄门面（store CRUD + sender + cURL + env）。
  final RequestDebugFacade facade;

  /// 目标集合 id（新建请求时用于落位）。
  final String? collectionId;

  /// 待编辑请求；为 `null` 表示为新建草稿。
  final DebugRequest? request;

  @override
  State<RequestEditorPage> createState() => _RequestEditorPageState();
}

class _RequestEditorPageState extends State<RequestEditorPage> {
  static const List<String> _httpMethods = <String>[
    'GET',
    'POST',
    'PUT',
    'PATCH',
    'DELETE',
    'HEAD',
    'OPTIONS',
  ];

  late final TextEditingController _name;
  late final TextEditingController _url;
  late final TextEditingController _body;
  late final TextEditingController _authUser;
  late final TextEditingController _authPass;
  late final TextEditingController _authToken;
  late final TextEditingController _authKeyName;
  late final TextEditingController _authKeyValue;

  final List<_KvRow> _params = <_KvRow>[];
  final List<_KvRow> _headers = <_KvRow>[];
  final List<_KvRow> _cookies = <_KvRow>[];

  late String _method;
  late DebugBodyKind _bodyKind;
  late DebugAuthType _authType;
  String _apiKeyIn = 'header';
  RequestEditorSegment _segment = RequestEditorSegment.params;

  DebugResponse? _response;
  bool _sending = false;
  bool _dirty = false;

  late final String _draftId;

  @override
  void initState() {
    super.initState();
    final request = widget.request;
    _draftId = request?.id ?? generateDebugId('req');
    _name = TextEditingController(text: request?.name ?? '');
    _url = TextEditingController(text: request?.url ?? '');
    _body = TextEditingController(text: request?.body ?? '');
    _method = request?.method ?? 'GET';
    if (!_httpMethods.contains(_method)) _method = 'GET';
    _bodyKind = request?.bodyKind ?? DebugBodyKind.none;
    _authType = request?.auth?.type ?? DebugAuthType.none;
    _apiKeyIn = request?.auth?.apiKeyIn ?? 'header';
    _authUser = TextEditingController(text: request?.auth?.username ?? '');
    _authPass = TextEditingController(text: request?.auth?.password ?? '');
    _authToken = TextEditingController(text: request?.auth?.token ?? '');
    _authKeyName = TextEditingController(text: request?.auth?.apiKeyName ?? '');
    _authKeyValue = TextEditingController(text: request?.auth?.apiKeyValue ?? '');
    for (final q in request?.query ?? const <DebugQueryParam>[]) {
      _params.add(_KvRow(name: q.name, value: q.value, enabled: q.enabled));
    }
    for (final h in request?.headers ?? const <DebugHeader>[]) {
      _headers.add(_KvRow(name: h.name, value: h.value, enabled: h.enabled));
    }
    for (final c in request?.cookies ?? const <DebugCookie>[]) {
      _cookies.add(_KvRow(name: c.name, value: c.value));
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    _body.dispose();
    _authUser.dispose();
    _authPass.dispose();
    _authToken.dispose();
    _authKeyName.dispose();
    _authKeyValue.dispose();
    for (final row in <_KvRow>[..._params, ..._headers, ..._cookies]) {
      row.dispose();
    }
    super.dispose();
  }

  void _markDirty() => setState(() => _dirty = true);

  RequestDebugFacade get _facade => widget.facade;

  // ==================== 草稿 ====================

  DebugAuth? _composeAuth() {
    switch (_authType) {
      case DebugAuthType.none:
        return null;
      case DebugAuthType.basic:
        return DebugAuth(
          type: DebugAuthType.basic,
          username: _authUser.text,
          password: _authPass.text,
        );
      case DebugAuthType.bearer:
        return DebugAuth(type: DebugAuthType.bearer, token: _authToken.text);
      case DebugAuthType.apiKey:
        return DebugAuth(
          type: DebugAuthType.apiKey,
          apiKeyName: _authKeyName.text,
          apiKeyValue: _authKeyValue.text,
          apiKeyIn: _apiKeyIn,
        );
    }
  }

  DebugRequest _composeDraft() {
    final url = _url.text.trim();
    final rawName = _name.text.trim();
    return DebugRequest(
      id: _draftId,
      name: rawName.isEmpty ? (url.isEmpty ? '未命名请求' : url) : rawName,
      method: _method,
      url: url,
      headers: _headers
          .where((h) => h.nameCtrl.text.trim().isNotEmpty)
          .map((h) => DebugHeader(
                name: h.nameCtrl.text.trim(),
                value: h.valueCtrl.text,
                enabled: h.enabled,
              ))
          .toList(),
      query: _params
          .where((p) => p.nameCtrl.text.trim().isNotEmpty)
          .map((p) => DebugQueryParam(
                name: p.nameCtrl.text.trim(),
                value: p.valueCtrl.text,
                enabled: p.enabled,
              ))
          .toList(),
      body: _body.text,
      bodyKind: _bodyKind,
      auth: _composeAuth(),
      cookies: _cookies
          .where((c) => c.nameCtrl.text.trim().isNotEmpty)
          .map((c) => DebugCookie(
                name: c.nameCtrl.text.trim(),
                value: c.valueCtrl.text,
              ))
          .toList(),
      collectionId: widget.collectionId ?? widget.request?.collectionId,
    );
  }

  // ==================== 环境变量 ====================

  static final RegExp _placeholder = RegExp(r'\{\{([^{}]+)\}\}');

  List<InlineSpan> _highlightSpans(
    BuildContext context,
    String text,
    DebugEnvironment env,
  ) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final base = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    final spans = <InlineSpan>[];
    var last = 0;
    for (final match in _placeholder.allMatches(text)) {
      if (match.start > last) {
        spans.add(TextSpan(text: text.substring(last, match.start), style: base));
      }
      final name = match.group(1)!.trim();
      final value = env.vars[name];
      if (value != null) {
        spans.add(TextSpan(
          text: value,
          style: base?.copyWith(
            color: scheme.primary,
            fontWeight: AppTypography.weightSemiBold,
          ),
        ));
      } else {
        spans.add(TextSpan(
          text: match.group(0),
          style: base?.copyWith(
            color: scheme.error,
            decoration: TextDecoration.underline,
            decorationColor: scheme.error,
          ),
        ));
      }
      last = match.end;
    }
    if (last < text.length) {
      spans.add(TextSpan(text: text.substring(last), style: base));
    }
    return spans;
  }

  Future<void> _insertVariable() async {
    final env = _facade.store.activeEnvironment;
    if (env == null || env.vars.isEmpty) return;
    final picked = await AppSheet.showCustom<String>(
      context: context,
      builder: (_) => AppSheetScaffold(
        title: '插入环境变量',
        subtitle: env.name,
        contentPadding: AppSpacing.onlyHorizontalXL,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final entry in env.vars.entries)
              Material(
                type: MaterialType.transparency,
                child: ListTile(
                  key: Key('request-editor-insert-var-${entry.key}'),
                  title: Text('{{${entry.key}}}'),
                  subtitle: Text(entry.value),
                  onTap: () => Navigator.of(context).pop(entry.key),
                ),
              ),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    final insert = '{{$picked}}';
    final selection = _url.selection;
    final start = selection.isValid ? selection.start : _url.text.length;
    final end = selection.isValid ? selection.end : _url.text.length;
    final next = _url.text.replaceRange(start, end, insert);
    _url.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: start + insert.length),
    );
    _markDirty();
  }

  // ==================== 动作 ====================

  Future<void> _send() async {
    if (_sending) return;
    final draft = _composeDraft();
    final env = _facade.store.activeEnvironment;
    String resolve(String text) =>
        env == null ? text : _facade.resolveEnvIn(text, env).text;

    final headers = draft.headers
        .map((h) => DebugHeader(
              name: h.name,
              value: resolve(h.value),
              enabled: h.enabled,
            ))
        .toList();
    final query = draft.query
        .map((q) => DebugQueryParam(
              name: q.name,
              value: resolve(q.value),
              enabled: q.enabled,
            ))
        .toList();

    setState(() {
      _sending = true;
      _segment = RequestEditorSegment.response;
    });
    final response = await _facade.send(
      method: draft.method,
      url: resolve(draft.url),
      headers: headers,
      query: query,
      body: resolve(draft.body),
    );
    if (!mounted) return;
    setState(() {
      _sending = false;
      _response = response;
    });
  }

  String? _persistedCollectionId() =>
      widget.collectionId ?? widget.request?.collectionId;

  Future<void> _save() async {
    final draft = _composeDraft();
    final existing = widget.request?.id;
    if (existing != null && _facade.store.requestById(existing) != null) {
      _facade.store.updateRequest(draft);
    } else {
      final collectionId = _persistedCollectionId();
      if (collectionId == null) {
        AppDialogs.showError('无法保存：请从集合中新建请求');
        return;
      }
      _facade.store.addRequest(collectionId, draft);
    }
    await _facade.save();
    if (!mounted) return;
    setState(() => _dirty = false);
    AppDialogs.showSuccess('请求已保存');
  }

  Future<void> _saveAs() async {
    final collectionId = _persistedCollectionId();
    if (collectionId == null) {
      AppDialogs.showError('无法另存为：请从集合中新建请求');
      return;
    }
    final draft = _composeDraft();
    final clone = draft.copyWith(
      id: generateDebugId('req'),
      name: '${draft.name} 副本',
      collectionId: collectionId,
    );
    _facade.store.addRequest(collectionId, clone);
    await _facade.save();
    if (!mounted) return;
    setState(() => _dirty = false);
    AppDialogs.showSuccess('已另存为新请求');
  }

  Future<void> _exportCurl() async {
    final curl = _facade.toCurl(_composeDraft());
    await AppSheet.showCustom<void>(
      context: context,
      builder: (sheetContext) => AppSheetScaffold(
        title: '导出 cURL',
        contentPadding: AppSpacing.onlyHorizontalXL,
        content: SelectableText(curl, style: AppTypography.code),
        actions: [
          FilledButton(
            key: const Key('request-editor-export-curl-close'),
            onPressed: () => Navigator.of(sheetContext).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  // ==================== 离开 ====================

  Future<void> _handleLeave() async {
    if (!_dirty) {
      if (mounted) Navigator.of(context).pop();
      return;
    }
    final discard = await AppDialogs.showConfirmSheet(
      title: '放弃未保存的修改？',
      message: '当前请求有未保存的修改，离开后将丢失。',
      confirmText: '放弃',
      cancelText: '继续编辑',
      isDangerous: true,
    );
    if (!mounted) return;
    if (discard == true) Navigator.of(context).pop();
  }

  // ==================== 构建 ====================

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _handleLeave();
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            key: const Key('request-editor-back'),
            tooltip: '返回',
            icon: const Icon(TablerIcons.arrow_left),
            onPressed: _handleLeave,
          ),
          title: TextField(
            key: const Key('request-editor-name'),
            controller: _name,
            textInputAction: TextInputAction.done,
            decoration: const InputDecoration(
              hintText: '请求名称',
              border: InputBorder.none,
            ),
            onChanged: (_) => _markDirty(),
          ),
        ),
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildTopBar(context),
            _buildSegmentSwitch(context),
            const Divider(height: 1),
            Expanded(child: _buildSegmentBody(context)),
            const Divider(height: 1),
            _buildBottomActions(context),
          ],
        ),
      ),
    );
  }

  Widget _buildTopBar(BuildContext context) {
    return Padding(
      padding: AppSpacing.allLG,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildMethodDropdown(context),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  key: const Key('request-editor-url'),
                  controller: _url,
                  textInputAction: TextInputAction.done,
                  decoration: InputDecoration(
                    hintText: 'https://api.example/path',
                    border: const OutlineInputBorder(),
                    suffixIcon: IconButton(
                      key: const Key('request-editor-insert-var'),
                      tooltip: '插入环境变量',
                      icon: const Icon(TablerIcons.variable),
                      onPressed: _insertVariable,
                    ),
                  ),
                  onChanged: (_) => _markDirty(),
                ),
                _buildEnvPreview(context),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.xs),
          IconButton.filled(
            key: const Key('request-editor-send-top'),
            tooltip: '发送',
            icon: const Icon(TablerIcons.send),
            onPressed: _sending ? null : _send,
          ),
        ],
      ),
    );
  }

  Widget _buildMethodDropdown(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: AppSpacing.onlyHorizontalSM,
      decoration: BoxDecoration(
        border: Border.all(color: scheme.outline),
        borderRadius: AppRadius.allSM,
      ),
      child: DropdownButton<String>(
        key: const Key('request-editor-method'),
        value: _method,
        underline: const SizedBox.shrink(),
        items: _httpMethods
            .map(
              (method) => DropdownMenuItem<String>(
                value: method,
                child: Text(method),
              ),
            )
            .toList(),
        onChanged: (value) {
          if (value == null || value == _method) return;
          setState(() {
            _method = value;
            _dirty = true;
          });
        },
      ),
    );
  }

  Widget _buildEnvPreview(BuildContext context) {
    final env = _facade.store.activeEnvironment;
    final text = _url.text;
    if (env == null || text.isEmpty) return const SizedBox.shrink();
    final missing = _facade.resolveEnvIn(text, env).missing;
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text.rich(
            TextSpan(children: _highlightSpans(context, text, env)),
            key: const Key('request-editor-url-preview'),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          if (missing.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.xs),
              child: Wrap(
                key: const Key('request-editor-env-missing'),
                spacing: AppSpacing.xs,
                runSpacing: AppSpacing.xs,
                children: [
                  for (final name in missing)
                    Chip(
                      key: Key('request-editor-env-missing-$name'),
                      label: Text(name),
                      visualDensity: VisualDensity.compact,
                      backgroundColor:
                          Theme.of(context).colorScheme.errorContainer,
                      labelStyle: Theme.of(context).textTheme.labelSmall?.copyWith(
                            color: Theme.of(context).colorScheme.onErrorContainer,
                          ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildSegmentSwitch(BuildContext context) {
    return Padding(
      padding: AppSpacing.onlyHorizontalLG,
      child: Align(
        alignment: Alignment.centerLeft,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: AppSegmentedButton<RequestEditorSegment>(
            value: _segment,
            density: AppSegmentedButton.mediumDensity,
            segments: const <AppSegment<RequestEditorSegment>>[
              AppSegment(
                value: RequestEditorSegment.params,
                label: '参数',
                key: Key('request-editor-segment-params'),
              ),
              AppSegment(
                value: RequestEditorSegment.headers,
                label: '头',
                key: Key('request-editor-segment-headers'),
              ),
              AppSegment(
                value: RequestEditorSegment.body,
                label: '体',
                key: Key('request-editor-segment-body'),
              ),
              AppSegment(
                value: RequestEditorSegment.auth,
                label: '认证',
                key: Key('request-editor-segment-auth'),
              ),
              AppSegment(
                value: RequestEditorSegment.cookies,
                label: 'Cookie',
                key: Key('request-editor-segment-cookies'),
              ),
              AppSegment(
                value: RequestEditorSegment.response,
                label: '响应',
                key: Key('request-editor-segment-response'),
              ),
            ],
            onChanged: (segment) => setState(() => _segment = segment),
          ),
        ),
      ),
    );
  }

  Widget _buildSegmentBody(BuildContext context) {
    switch (_segment) {
      case RequestEditorSegment.params:
        return _buildKvList(
          rows: _params,
          addLabel: '添加参数',
          addKey: const Key('request-editor-params-add'),
          keyPrefix: 'request-editor-param',
          nameHint: '参数名',
        );
      case RequestEditorSegment.headers:
        return _buildKvList(
          rows: _headers,
          addLabel: '添加请求头',
          addKey: const Key('request-editor-headers-add'),
          keyPrefix: 'request-editor-header',
          nameHint: '请求头',
          allowDisable: true,
        );
      case RequestEditorSegment.body:
        return _buildBodyEditor(context);
      case RequestEditorSegment.auth:
        return _buildAuthEditor(context);
      case RequestEditorSegment.cookies:
        return _buildKvList(
          rows: _cookies,
          addLabel: '添加 Cookie',
          addKey: const Key('request-editor-cookies-add'),
          keyPrefix: 'request-editor-cookie',
          nameHint: 'Cookie 名',
        );
      case RequestEditorSegment.response:
        return _buildResponse(context);
    }
  }

  Widget _buildKvList({
    required List<_KvRow> rows,
    required String addLabel,
    required Key addKey,
    required String keyPrefix,
    required String nameHint,
    bool allowDisable = false,
  }) {
    return ListView(
      padding: AppSpacing.allLG,
      children: [
        for (var i = 0; i < rows.length; i++) _buildKvRow(rows[i], keyPrefix, nameHint, allowDisable),
        const SizedBox(height: AppSpacing.sm),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: addKey,
            onPressed: () => setState(() {
              rows.add(_KvRow());
              _dirty = true;
            }),
            icon: const Icon(TablerIcons.plus),
            label: Text(addLabel),
          ),
        ),
      ],
    );
  }

  Widget _buildKvRow(_KvRow row, String keyPrefix, String nameHint, bool allowDisable) {
    return Padding(
      padding: AppSpacing.onlyVerticalXS,
      child: Row(
        children: [
          if (allowDisable)
            Checkbox(
              value: row.enabled,
              onChanged: (value) => setState(() {
                row.enabled = value ?? false;
                _dirty = true;
              }),
            ),
          Expanded(
            flex: 2,
            child: TextField(
              controller: row.nameCtrl,
              decoration: InputDecoration(
                hintText: nameHint,
                isDense: true,
                border: const OutlineInputBorder(),
              ),
              onChanged: (_) => _markDirty(),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            flex: 3,
            child: TextField(
              controller: row.valueCtrl,
              decoration: const InputDecoration(
                hintText: '值',
                isDense: true,
                border: OutlineInputBorder(),
              ),
              onChanged: (_) => _markDirty(),
            ),
          ),
          IconButton(
            tooltip: '删除',
            icon: const Icon(TablerIcons.trash),
            onPressed: () => setState(() {
              row.dispose();
              _rowsOf(keyPrefix).remove(row);
              _dirty = true;
            }),
          ),
        ],
      ),
    );
  }

  List<_KvRow> _rowsOf(String keyPrefix) {
    switch (keyPrefix) {
      case 'request-editor-header':
        return _headers;
      case 'request-editor-cookie':
        return _cookies;
      default:
        return _params;
    }
  }

  Widget _buildBodyEditor(BuildContext context) {
    return Padding(
      padding: AppSpacing.allLG,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DropdownButtonFormField<DebugBodyKind>(
            key: const Key('request-editor-body-kind'),
            initialValue: _bodyKind,
            decoration: const InputDecoration(
              labelText: '类型',
              border: OutlineInputBorder(),
            ),
            items: DebugBodyKind.values
                .map(
                  (kind) => DropdownMenuItem<DebugBodyKind>(
                    value: kind,
                    child: Text(kind.wire),
                  ),
                )
                .toList(),
            onChanged: (value) {
              if (value == null) return;
              setState(() {
                _bodyKind = value;
                _dirty = true;
              });
            },
          ),
          const SizedBox(height: AppSpacing.md),
          Expanded(
            child: TextField(
              key: const Key('request-editor-body'),
              controller: _body,
              maxLines: null,
              expands: true,
              textAlignVertical: TextAlignVertical.top,
              decoration: const InputDecoration(
                hintText: '请求体',
                border: OutlineInputBorder(),
              ),
              onChanged: (_) => _markDirty(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAuthEditor(BuildContext context) {
    return ListView(
      padding: AppSpacing.allLG,
      children: [
        DropdownButtonFormField<DebugAuthType>(
          key: const Key('request-editor-auth-type'),
          initialValue: _authType,
          decoration: const InputDecoration(
            labelText: '认证类型',
            border: OutlineInputBorder(),
          ),
          items: DebugAuthType.values
              .map(
                (type) => DropdownMenuItem<DebugAuthType>(
                  value: type,
                  child: Text(type.wire),
                ),
              )
              .toList(),
          onChanged: (value) {
            if (value == null) return;
            setState(() {
              _authType = value;
              _dirty = true;
            });
          },
        ),
        const SizedBox(height: AppSpacing.md),
        if (_authType == DebugAuthType.basic) ...[
          _field(_authUser, '用户名'),
          _field(_authPass, '密码'),
        ] else if (_authType == DebugAuthType.bearer)
          _field(_authToken, 'Token')
        else if (_authType == DebugAuthType.apiKey) ...[
          _field(_authKeyName, 'Key 名'),
          _field(_authKeyValue, 'Key 值'),
          DropdownButtonFormField<String>(
            key: const Key('request-editor-auth-apikey-in'),
            initialValue: _apiKeyIn,
            decoration: const InputDecoration(
              labelText: '注入位置',
              border: OutlineInputBorder(),
            ),
            items: const [
              DropdownMenuItem<String>(value: 'header', child: Text('Header')),
              DropdownMenuItem<String>(value: 'query', child: Text('Query')),
            ],
            onChanged: (value) {
              if (value == null) return;
              setState(() {
                _apiKeyIn = value;
                _dirty = true;
              });
            },
          ),
        ] else
          Text(
            '未使用认证',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
      ],
    );
  }

  Widget _field(TextEditingController controller, String label) {
    return Padding(
      padding: AppSpacing.onlyBottomMD,
      child: TextField(
        controller: controller,
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
        ),
        onChanged: (_) => _markDirty(),
      ),
    );
  }

  Widget _buildResponse(BuildContext context) {
    if (_sending) {
      return const Center(child: AppLoading(size: AppLoadingSize.medium));
    }
    final response = _response;
    final theme = Theme.of(context);
    if (response == null) {
      return Center(
        child: Text(
          '尚未发送请求',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }
    final env = _facade.store.activeEnvironment;
    final url =
        env == null ? _url.text : _facade.resolveEnvIn(_url.text, env).text;
    return ResponseViewer(
      response: response,
      method: _method,
      url: url,
      onSaveAsRewrite: _facade.setCaptureRule,
    );
  }

  Widget _buildBottomActions(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: AppSpacing.allLG,
        child: Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                key: const Key('request-editor-send'),
                onPressed: _sending ? null : _send,
                icon: const Icon(TablerIcons.send),
                label: const Text('发送'),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            TextButton(
              key: const Key('request-editor-save'),
              onPressed: _save,
              child: const Text('保存'),
            ),
            TextButton(
              key: const Key('request-editor-save-as'),
              onPressed: _saveAs,
              child: const Text('另存为'),
            ),
            TextButton(
              key: const Key('request-editor-export-curl'),
              onPressed: _exportCurl,
              child: const Text('导出 cURL'),
            ),
          ],
        ),
      ),
    );
  }
}

/// 键值编辑行（参数 / 头 / Cookie 共用）。
class _KvRow {
  _KvRow({String name = '', String value = '', this.enabled = true})
      : nameCtrl = TextEditingController(text: name),
        valueCtrl = TextEditingController(text: value);

  final TextEditingController nameCtrl;
  final TextEditingController valueCtrl;
  bool enabled;

  void dispose() {
    nameCtrl.dispose();
    valueCtrl.dispose();
  }
}
