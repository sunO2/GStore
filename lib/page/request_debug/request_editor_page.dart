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

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';

import 'package:gstore/core/design/app_components.dart';
import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/design/app_radius.dart';
import 'package:gstore/core/design/app_sheet.dart';
import 'package:gstore/core/design/app_spacing.dart';
import 'package:gstore/core/design/app_typography.dart';
import 'package:gstore/core/request_debug/request_debug.dart';

import 'cookie_manager_sheet.dart';
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

  // 自适应字段的 state key：用于工具栏「上一个 / 下一个」在字段间移动焦点。
  final GlobalKey<AppEditableFieldState> _urlFieldKey =
      GlobalKey<AppEditableFieldState>();
  final GlobalKey<AppEditableFieldState> _authUserFieldKey =
      GlobalKey<AppEditableFieldState>();
  final GlobalKey<AppEditableFieldState> _authPassFieldKey =
      GlobalKey<AppEditableFieldState>();
  final GlobalKey<AppEditableFieldState> _authTokenFieldKey =
      GlobalKey<AppEditableFieldState>();
  final GlobalKey<AppEditableFieldState> _authKeyNameFieldKey =
      GlobalKey<AppEditableFieldState>();
  final GlobalKey<AppEditableFieldState> _authKeyValueFieldKey =
      GlobalKey<AppEditableFieldState>();

  final List<_KvRow> _params = <_KvRow>[];
  final List<_KvRow> _headers = <_KvRow>[];
  final List<_KvRow> _cookies = <_KvRow>[];

  late String _method;
  late DebugBodyKind _bodyKind;
  late DebugBinarySource _binarySource;
  late DebugAuthType _authType;
  String _apiKeyIn = 'header';
  RequestEditorSegment _segment = RequestEditorSegment.params;

  DebugResponse? _response;
  bool _sending = false;
  bool _dirty = false;

  /// 请求体 JSON 格式化失败的内联错误；成功格式化或再次编辑后清除。
  String? _bodyError;

  /// URL ⇄ 参数同步的重入保护：任一方向的同步过程中绝不再次触发同步，
  /// 避免显示 URL 的程序化回写被误判为一次新提交而振荡。
  bool _syncing = false;

  late final String _draftId;

  @override
  void initState() {
    super.initState();
    final request = widget.request;
    _draftId = request?.id ?? generateDebugId('req');
    // 载入时**始终**解析 URL 查询：`request.query` 非空则以它为准合并（URL 独有
    // 键保留、同名键以 query 为准）；否则采用解析出的行。显示 URL 始终为合并后的
    // `path?query#fragment`。解析绝不 `Uri.parse`、绝不解析 `{{var}}`、绝不抛。
    final parsed = parseUrlQuery(request?.url ?? '');
    final storedQuery = request?.query ?? const <DebugQueryParam>[];
    final initialParams = storedQuery.isEmpty
        ? parsed.params
        : mergeParams(parsed.params, storedQuery);
    _name = TextEditingController(text: request?.name ?? '');
    _url = TextEditingController(
      text: rebuildUrl(parsed.base, parsed.fragment, initialParams),
    );
    _body = TextEditingController(text: request?.body ?? '');
    _method = request?.method ?? 'GET';
    if (!_httpMethods.contains(_method)) _method = 'GET';
    _bodyKind = request?.bodyKind ?? DebugBodyKind.none;
    _binarySource = request?.binarySource ?? DebugBinarySource.raw;
    _authType = request?.auth?.type ?? DebugAuthType.none;
    _apiKeyIn = request?.auth?.apiKeyIn ?? 'header';
    _authUser = TextEditingController(text: request?.auth?.username ?? '');
    _authPass = TextEditingController(text: request?.auth?.password ?? '');
    _authToken = TextEditingController(text: request?.auth?.token ?? '');
    _authKeyName = TextEditingController(text: request?.auth?.apiKeyName ?? '');
    _authKeyValue = TextEditingController(text: request?.auth?.apiKeyValue ?? '');
    for (final controller in <TextEditingController>[
      _url,
      _authUser,
      _authPass,
      _authToken,
      _authKeyName,
      _authKeyValue,
    ]) {
      _bindDirty(controller);
    }
    for (final q in initialParams) {
      _params.add(_newRow(name: q.name, value: q.value, enabled: q.enabled));
    }
    for (final h in request?.headers ?? const <DebugHeader>[]) {
      _headers.add(_newRow(name: h.name, value: h.value, enabled: h.enabled));
    }
    for (final c in request?.cookies ?? const <DebugCookie>[]) {
      _cookies.add(_newRow(name: c.name, value: c.value));
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

  /// 绑定自适应字段 controller：文本变化（含弹层写回）即标记脏值并重建，
  /// 使环境预览等派生 UI 同步刷新。
  void _bindDirty(TextEditingController controller) {
    controller.addListener(_onFieldChanged);
  }

  void _onFieldChanged() {
    if (!mounted) return;
    // 始终 setState：文本变化后需要刷新派生 UI（如 URL 环境预览）。
    setState(() => _dirty = true);
  }

  _KvRow _newRow({String name = '', String value = '', bool enabled = true}) {
    final row = _KvRow(
      id: generateDebugId('kv'),
      name: name,
      value: value,
      enabled: enabled,
    );
    _bindDirty(row.nameCtrl);
    _bindDirty(row.valueCtrl);
    return row;
  }

  /// 提交某行（行内 done / 弹层完成）后的统一处理：
  /// - 参数行回写 URL；
  /// - 若提交的是**最后一个非空行**，追加一个空行便于继续录入。
  void _onRowCommitted(_KvRow row, String keyPrefix) {
    final rows = _rowsOf(keyPrefix);
    final isLast = rows.isNotEmpty && identical(rows.last, row);
    final hasContent = row.nameCtrl.text.trim().isNotEmpty ||
        row.valueCtrl.text.trim().isNotEmpty;
    setState(() {
      _dirty = true;
      if (isLast && hasContent) rows.add(_newRow());
    });
    if (keyPrefix == 'request-editor-param') _syncUrlFromParams();
  }

  /// 行从列表移除后，等首帧重建（TextField 已卸载）再释放其 controller，
  /// 避免「controller used after dispose」。
  void _disposeRowsAfterFrame(List<_KvRow> rows) {
    if (rows.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final row in rows) {
        row.dispose();
      }
    });
  }

  /// 删除一行：先出列表并重建，再延迟释放 controller；参数行回写 URL。
  void _removeRow(String keyPrefix, _KvRow row) {
    final isParams = keyPrefix == 'request-editor-param';
    setState(() {
      _rowsOf(keyPrefix).remove(row);
      _dirty = true;
    });
    _disposeRowsAfterFrame(<_KvRow>[row]);
    if (isParams) _syncUrlFromParams();
  }

  RequestDebugFacade get _facade => widget.facade;

  // ==================== URL ⇄ 参数同步 ====================

  /// 从参数行 compose 出 `DebugQueryParam`（仅非空名字），同步与保存共用。
  List<DebugQueryParam> _currentParams() => _params
      .where((p) => p.nameCtrl.text.trim().isNotEmpty)
      .map((p) => DebugQueryParam(
            name: p.nameCtrl.text.trim(),
            value: p.valueCtrl.text,
            enabled: p.enabled,
          ))
      .toList();

  /// 用 [params] 重建参数行：按稳定 id 复用已有行（同名参数优先复用其行对象，
  /// 从而保留 controller / 焦点），不足则新建，多余则延迟释放。
  void _applyParamRows(List<DebugQueryParam> params) {
    final used = <String>{};
    final next = <_KvRow>[];
    for (final param in params) {
      _KvRow? row;
      for (final candidate in _params) {
        if (!used.contains(candidate.id) &&
            candidate.nameCtrl.text.trim() == param.name) {
          row = candidate;
          break;
        }
      }
      row ??= _newRow();
      used.add(row.id);
      row.nameCtrl.text = param.name;
      row.valueCtrl.text = param.value;
      row.enabled = param.enabled;
      next.add(row);
    }
    final removed = _params.where((row) => !next.contains(row)).toList();
    _params
      ..clear()
      ..addAll(next);
    _disposeRowsAfterFrame(removed);
  }

  /// 参数 → URL（提交驱动）：把参数行重建为显示 URL，保留 path 与 `#fragment`。
  ///
  /// 由参数行的提交（行内 done / 弹层完成）与增删触发；**绝不**监听每次击键。
  void _syncUrlFromParams() {
    if (_syncing) return;
    _syncing = true;
    try {
      final parsed = parseUrlQuery(_url.text);
      _url.text = rebuildUrl(parsed.base, parsed.fragment, _currentParams());
    } finally {
      _syncing = false;
    }
  }

  /// URL → 参数（提交驱动）：解析刚提交的 URL，把查询并入参数行。
  ///
  /// 最新 URL 输入对同名键优先（覆盖），URL 独有键追加，既有参数行独有键保留。
  /// 解析绝不解析 `{{var}}`、绝不抛异常（畸形输入兜底为「无查询」）。
  ///
  /// T15 的「URL 提交即发送」应先调用本方法，再做发送。
  void _syncParamsFromUrl() {
    if (_syncing) return;
    _syncing = true;
    try {
      final parsed = parseUrlQuery(_url.text);
      final merged = mergeParams(_currentParams(), parsed.params);
      _applyParamRows(merged);
      _url.text = rebuildUrl(parsed.base, parsed.fragment, merged);
    } finally {
      _syncing = false;
    }
    if (mounted) setState(() => _dirty = true);
  }

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
    // 规范化持久化：显示 URL 的查询移入 `query[]`，`url` 只留 path + `#fragment`。
    final parsed = parseUrlQuery(_url.text.trim());
    final url = rebuildUrl(parsed.base, parsed.fragment, const <DebugQueryParam>[]);
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
      query: _currentParams(),
      body: _body.text,
      bodyKind: _bodyKind,
      binarySource: _binarySource,
      binaryFilePath: _binarySource == DebugBinarySource.file
          ? _body.text.trim()
          : null,
      multipartFields: widget.request?.multipartFields ?? const [],
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

  /// 弹出「插入环境变量」选择器，并把 `{{name}}` 插入 [target] 的当前选区。
  ///
  /// [target] 是当前编辑面的 controller（弹层打开时为本地草稿），因此插入
  /// 不会命中已过期的绑定值选区。
  Future<void> _pickInsertVariable(TextEditingController target) async {
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
    AppEditorToolbar.insertAtCursor(target, '{{$picked}}');
    _markDirty();
  }

  // ==================== 自适应字段工具栏 / 焦点 ====================

  static const List<String> _commonHeaderNames = <String>[
    'Content-Type',
    'Authorization',
    'Accept',
    'User-Agent',
    'X-Request-Id',
  ];

  /// 常见请求头名 + 历史请求里出现过的最近值（去重，最新优先）。
  List<String> _headerSuggestions() {
    final names = <String>[..._commonHeaderNames];
    final recent = <String>[];
    for (final entry in _facade.store.history) {
      for (final h in entry.request.headers) {
        final value = h.value.trim();
        final name = h.name.trim();
        if (value.isNotEmpty &&
            !names.contains(value) &&
            !recent.contains(value)) {
          recent.add(value);
        }
        if (name.isNotEmpty &&
            !names.contains(name) &&
            !recent.contains(name)) {
          recent.add(name);
        }
      }
      if (recent.length >= 8) break;
    }
    return <String>[...names, ...recent];
  }

  Widget _insertVarButton(TextEditingController controller) {
    return IconButton(
      key: const Key('request-editor-insert-var'),
      tooltip: '插入环境变量',
      icon: const Icon(TablerIcons.variable),
      visualDensity: VisualDensity.compact,
      onPressed: () => _pickInsertVariable(controller),
    );
  }

  /// 弹层工具栏：上一个/下一个字段 + 粘贴/清空（可选插入变量 / 建议 chips）。
  AppEditableFieldToolbarBuilder _sheetToolbar({
    required GlobalKey<AppEditableFieldState> fieldKey,
    bool allowInsertVar = false,
    List<String> Function()? suggestionsBuilder,
  }) {
    return (context, controller) {
      final suggestions = suggestionsBuilder?.call() ?? const <String>[];
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: AppSpacing.xs,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (allowInsertVar) _insertVarButton(controller),
              AppEditorToolbar(
                controller: controller,
                onPrevious: () => _focusRelative(fieldKey, -1),
                onNext: () => _focusRelative(fieldKey, 1),
              ),
            ],
          ),
          if (suggestions.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.xs),
            AppSuggestionChips(suggestions, controller: controller),
          ],
        ],
      );
    };
  }

  /// 当前分段下可聚焦的编辑字段顺序（仅枚举已挂载的字段）。
  List<GlobalKey<AppEditableFieldState>> _focusOrder() {
    final order = <GlobalKey<AppEditableFieldState>>[_urlFieldKey];
    void addRows(List<_KvRow> rows) {
      for (final row in rows) {
        order.add(row.nameFieldKey);
        order.add(row.valueFieldKey);
      }
    }

    switch (_segment) {
      case RequestEditorSegment.params:
        addRows(_params);
        break;
      case RequestEditorSegment.headers:
        addRows(_headers);
        break;
      case RequestEditorSegment.cookies:
        addRows(_cookies);
        break;
      case RequestEditorSegment.auth:
        order.addAll(<GlobalKey<AppEditableFieldState>>[
          _authUserFieldKey,
          _authPassFieldKey,
          _authTokenFieldKey,
          _authKeyNameFieldKey,
          _authKeyValueFieldKey,
        ]);
        break;
      case RequestEditorSegment.body:
      case RequestEditorSegment.response:
        break;
    }
    return order.where((key) => key.currentState != null).toList();
  }

  void _focusRelative(GlobalKey<AppEditableFieldState> from, int delta) {
    final order = _focusOrder();
    final index = order.indexOf(from);
    if (index < 0 || order.length < 2) return;
    order[(index + delta) % order.length].currentState?.focus();
  }

  // ==================== 动作 ====================

  /// 把编辑器显式 cookie 组合为 `Cookie` 头值（跳过空名；同名保留首个）。
  ///
  /// **不**解析 cookie 内 `{{var}}`（与认证约定一致）。
  static String _cookieHeaderFrom(List<DebugCookie> cookies) {
    final parts = <String>[];
    final seen = <String>{};
    for (final cookie in cookies) {
      final name = cookie.name.trim();
      if (name.isEmpty || !seen.add(name)) continue;
      parts.add('$name=${cookie.value}');
    }
    return parts.join('; ');
  }

  /// 把显式 cookie 头并入 [headers]：命中同名 `Cookie` 头则与之合并（编辑器
  /// 条目优先），否则追加。
  static List<DebugHeader> _withCookieHeader(
    List<DebugHeader> headers,
    String cookieHeader,
  ) {
    final next = <DebugHeader>[];
    var replaced = false;
    for (final header in headers) {
      if (!replaced && header.name.toLowerCase() == 'cookie') {
        final merged =
            DebugCookieJar.mergeCookieHeader(cookieHeader, header.value);
        next.add(DebugHeader(
          name: header.name,
          value: merged,
          enabled: header.enabled,
        ));
        replaced = true;
      } else {
        next.add(header);
      }
    }
    if (!replaced) {
      next.add(DebugHeader(name: 'Cookie', value: cookieHeader));
    }
    return next;
  }

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

    // 认证真正生效：Basic / Bearer 注入 Authorization 头，APIKey 注入命名头或
    // 查询参数。**不**解析 auth 内的 `{{var}}`（与既有约定一致）。
    final applied = applyAuth(
      auth: draft.auth,
      headers: headers,
      query: query,
    );

    // 编辑器显式 Cookie 真正生效：并入 `Cookie` 头；与 jar 的同名去重由
    // `DebugSender` 在发送时完成（显式条目优先）。
    final cookieHeader = _cookieHeaderFrom(draft.cookies);
    var sendHeaders = cookieHeader.isEmpty
        ? applied.headers
        : _withCookieHeader(applied.headers, cookieHeader);

    // `bodyKind` 真正影响线缆：按类型编码为字节；`none` 走旧 `body` 路径。
    final bodyText = resolve(draft.body);
    final explicitContentType = _explicitContentType(sendHeaders);
    BodyEncodeResult? encoded;
    try {
      encoded = await _encodeDraftBody(
        draft,
        bodyText,
        explicitContentType: explicitContentType,
      );
    } catch (error) {
      if (!mounted) return;
      AppDialogs.showError('请求体编码失败：$error');
      return;
    }
    if (encoded != null &&
        encoded.contentType != null &&
        explicitContentType == null) {
      // 未显式设置 Content-Type 时按 bodyKind 自动补上。
      sendHeaders = <DebugHeader>[
        ...sendHeaders,
        DebugHeader(name: 'Content-Type', value: encoded.contentType!),
      ];
    }

    setState(() {
      _sending = true;
      _segment = RequestEditorSegment.response;
    });
    final response = await _facade.send(
      method: draft.method,
      url: resolve(draft.url),
      headers: sendHeaders,
      query: applied.query,
      body: bodyText,
      bodyBytes: encoded?.bytes,
    );
    if (!mounted) return;
    setState(() {
      _sending = false;
      _response = response;
    });
  }

  /// 按 [draft.bodyKind] 把请求体编码为线缆字节；`none` 返回 `null`（旧路径）。
  Future<BodyEncodeResult?> _encodeDraftBody(
    DebugRequest draft,
    String text, {
    required String? explicitContentType,
  }) async {
    switch (draft.bodyKind) {
      case DebugBodyKind.none:
        return null;
      case DebugBodyKind.json:
      case DebugBodyKind.text:
      case DebugBodyKind.formUrlEncoded:
        return encodeBody(BodyEncodeInput(
          kind: draft.bodyKind,
          text: text,
          contentType: explicitContentType,
        ));
      case DebugBodyKind.multipart:
        final parts = draft.multipartFields.isNotEmpty
            ? await resolveMultipartFields(draft.multipartFields)
            : parseMultipartText(text);
        return encodeBody(BodyEncodeInput(
          kind: DebugBodyKind.multipart,
          parts: parts,
          contentType: explicitContentType,
          boundary: multipartBoundaryOf(explicitContentType),
        ));
      case DebugBodyKind.binary:
        final bytes = await resolveBinaryBytes(
          text,
          draft.binarySource,
          filePath: draft.binaryFilePath,
        );
        return encodeBody(BodyEncodeInput(
          kind: DebugBodyKind.binary,
          binaryBytes: bytes,
          contentType: explicitContentType,
        ));
    }
  }

  /// 返回首个启用的 `Content-Type` 值（大小写不敏感；无则 `null`）。
  static String? _explicitContentType(List<DebugHeader> headers) {
    for (final header in headers) {
      if (header.enabled &&
          header.name.trim().toLowerCase() == 'content-type' &&
          header.value.isNotEmpty) {
        return header.value;
      }
    }
    return null;
  }

  /// 打开 Cookie jar 管理弹层（统一底部弹层）。
  Future<void> _openCookieManager() =>
      CookieManagerSheet.show(context, jar: _facade.sender.cookieJar);

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
                KeyedSubtree(
                  key: const Key('request-editor-url'),
                  child: AppEditableField(
                    key: _urlFieldKey,
                    controller: _url,
                    mode: AppEditableFieldMode.sheet,
                    label: '请求地址',
                    hintText: 'https://api.example/path',
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) {
                      // 先同步 URL 查询到参数行（sync-before-send），再发送：
                      // 否则刚输入的 `?a=1&b=2` 会在 composeDraft 规范化时被丢弃。
                      _syncParamsFromUrl();
                      _send();
                    },
                    toolbarBuilder: _sheetToolbar(
                      fieldKey: _urlFieldKey,
                      allowInsertVar: true,
                    ),
                  ),
                ),
                _buildEnvPreview(context),
              ],
            ),
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
    // 用 [AppTabBar] 取代分段按钮：可滚动、宽度随文本，且程序化 value 变更
    // 只同步选中态、不回流触发 onChanged（发送后自动切「响应」需要）。
    return Padding(
      padding: AppSpacing.onlyHorizontalLG,
      child: AppTabBar<RequestEditorSegment>(
        value: _segment,
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
        return Column(
          children: [
            Expanded(
              child: _buildKvList(
                rows: _cookies,
                addLabel: '添加 Cookie',
                addKey: const Key('request-editor-cookies-add'),
                keyPrefix: 'request-editor-cookie',
                nameHint: 'Cookie 名',
              ),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: AppSpacing.onlyHorizontalLG,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    key: const Key('request-editor-cookie-manage'),
                    onPressed: _openCookieManager,
                    icon: const Icon(TablerIcons.cookie),
                    label: const Text('管理 Cookie jar'),
                  ),
                ),
              ),
            ),
          ],
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
    final isParams = keyPrefix == 'request-editor-param';
    return ReorderableListView(
      padding: AppSpacing.allLG,
      buildDefaultDragHandles: false,
      header: _buildKvHeader(allowDisable: allowDisable),
      onReorderItem: (oldIndex, newIndex) {
        setState(() {
          // `onReorderItem` 已为「移除 oldIndex」调整 newIndex。
          final row = rows.removeAt(oldIndex);
          rows.insert(newIndex, row);
          _dirty = true;
        });
        if (isParams) _syncUrlFromParams();
      },
      footer: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: AppSpacing.sm,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              TextButton.icon(
                key: addKey,
                onPressed: () {
                  setState(() {
                    rows.add(_newRow());
                    _dirty = true;
                  });
                  if (isParams) _syncUrlFromParams();
                },
                icon: const Icon(TablerIcons.plus),
                label: Text(addLabel),
              ),
              TextButton.icon(
                key: const Key('request-editor-kv-bulk'),
                onPressed: () => _openBulkEdit(keyPrefix),
                icon: const Icon(TablerIcons.list_check),
                label: const Text('批量编辑'),
              ),
            ],
          ),
        ],
      ),
      children: [
        for (var i = 0; i < rows.length; i++)
          _buildKvRow(
            rows[i],
            keyPrefix,
            nameHint,
            allowDisable,
            i,
            key: ValueKey<String>('$keyPrefix-row-${rows[i].id}'),
          ),
      ],
    );
  }

  /// 键 / 值 表头（与数据行各列对齐）。
  Widget _buildKvHeader({required bool allowDisable}) {
    final theme = Theme.of(context);
    final style = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Padding(
      padding: AppSpacing.onlyVerticalXS,
      child: Row(
        children: [
          if (allowDisable) const SizedBox(width: 48),
          Expanded(flex: 2, child: Text('键', style: style)),
          const SizedBox(width: AppSpacing.sm),
          Expanded(flex: 3, child: Text('值', style: style)),
          const SizedBox(width: 40),
          const SizedBox(width: 40),
        ],
      ),
    );
  }

  Widget _buildKvRow(
    _KvRow row,
    String keyPrefix,
    String nameHint,
    bool allowDisable,
    int index, {
    Key? key,
  }) {
    // 参数行的「提交」触发 URL 回写；头 / Cookie 与 URL 无关（但仍自动追加）。
    void onCommitted(String _) => _onRowCommitted(row, keyPrefix);
    return Padding(
      key: key,
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
            child: KeyedSubtree(
              key: Key('$keyPrefix-name-$index'),
              child: AppEditableField(
                key: row.nameFieldKey,
                controller: row.nameCtrl,
                mode: AppEditableFieldMode.inline,
                hintText: nameHint,
                textInputAction: TextInputAction.next,
                onSubmitted: onCommitted,
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            flex: 3,
            child: KeyedSubtree(
              key: Key('$keyPrefix-value-$index'),
              child: AppEditableField(
                key: row.valueFieldKey,
                controller: row.valueCtrl,
                mode: AppEditableFieldMode.sheet,
                label: nameHint,
                hintText: '值',
                textInputAction: TextInputAction.next,
                onSubmitted: onCommitted,
                toolbarBuilder: _sheetToolbar(
                  fieldKey: row.valueFieldKey,
                  suggestionsBuilder: keyPrefix == 'request-editor-header'
                      ? _headerSuggestions
                      : null,
                ),
              ),
            ),
          ),
          // 显式拖拽手柄：buildDefaultDragHandles:false 下唯一拖拽入口；
          // 按下即先移除焦点，规避聚焦 TextField 参与拖拽时的 LeaderLayer 断言。
          SizedBox(
            width: 40,
            height: 40,
            child: Listener(
              key: Key('$keyPrefix-drag-$index'),
              onPointerDown: (_) =>
                  FocusManager.instance.primaryFocus?.unfocus(),
              child: ReorderableDragStartListener(
                index: index,
                child: const Icon(TablerIcons.grip_vertical),
              ),
            ),
          ),
          IconButton(
            key: Key('$keyPrefix-delete-$index'),
            tooltip: '删除',
            icon: const Icon(TablerIcons.trash),
            onPressed: () => _removeRow(keyPrefix, row),
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

  /// 打开批量编辑弹层；导入成功后把解析出的行追加到对应列表。
  ///
  /// 非法行由弹层就地反馈（`request-editor-kv-bulk-error`），**不**改动既有行。
  Future<void> _openBulkEdit(String keyPrefix) async {
    final parsed = await AppSheet.showCustom<List<_KvDraft>>(
      context: context,
      builder: (_) => const _KvBulkEditSheet(),
    );
    if (parsed == null || parsed.isEmpty || !mounted) return;
    final rows = _rowsOf(keyPrefix);
    setState(() {
      for (final draft in parsed) {
        rows.add(_newRow(name: draft.name, value: draft.value));
      }
      _dirty = true;
    });
    if (keyPrefix == 'request-editor-param') _syncUrlFromParams();
  }

  /// 校验并美化当前请求体 JSON（单一事实来源）。
  ///
  /// - 仅当 [DebugBodyKind.json] 生效；`jsonDecode` 成功后以 2 空格缩进写回
  ///   [_body]，并清除内联错误；
  /// - 解析失败时**不改动** [_body]，仅设置 [_bodyError]；
  /// - 绝不逐键自动格式化（只由显式动作触发）。
  void _formatBodyJson() {
    if (_bodyKind != DebugBodyKind.json) return;
    final raw = _body.text;
    if (raw.trim().isEmpty) {
      if (_bodyError != null) setState(() => _bodyError = null);
      return;
    }
    final String pretty;
    try {
      pretty = const JsonEncoder.withIndent('  ').convert(jsonDecode(raw));
    } catch (_) {
      setState(() => _bodyError = 'JSON 格式错误，无法格式化');
      return;
    }
    setState(() {
      _body
        ..text = pretty
        ..selection = TextSelection.collapsed(offset: pretty.length);
      _bodyError = null;
      _dirty = true;
    });
  }

  /// 请求体输入框的提示文案（随 `bodyKind` / 二进制来源变化）。
  String _bodyHintText() {
    switch (_bodyKind) {
      case DebugBodyKind.multipart:
        return '每行一个字段：name=value';
      case DebugBodyKind.binary:
        switch (_binarySource) {
          case DebugBinarySource.raw:
            return '原始文本（按 UTF-8 字节发送）';
          case DebugBinarySource.hex:
            return '十六进制，如 0a ff 10';
          case DebugBinarySource.base64:
            return 'Base64 文本';
          case DebugBinarySource.file:
            return '本地文件绝对路径';
        }
      case DebugBodyKind.formUrlEncoded:
        return '如 a=1&b=hello world';
      case DebugBodyKind.json:
      case DebugBodyKind.text:
      case DebugBodyKind.none:
        return '请求体';
    }
  }

  Widget _buildBodyEditor(BuildContext context) {
    final theme = Theme.of(context);
    final isJson = _bodyKind == DebugBodyKind.json;
    final isBinary = _bodyKind == DebugBodyKind.binary;
    return Padding(
      padding: AppSpacing.allLG,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<DebugBodyKind>(
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
                      _bodyError = null;
                      _dirty = true;
                    });
                  },
                ),
              ),
              if (isJson) ...[
                const SizedBox(width: AppSpacing.sm),
                IconButton(
                  key: const Key('request-editor-body-format'),
                  tooltip: '格式化 JSON',
                  icon: const Icon(TablerIcons.braces),
                  onPressed: _formatBodyJson,
                ),
              ],
            ],
          ),
          if (isBinary) ...[
            const SizedBox(height: AppSpacing.md),
            DropdownButtonFormField<DebugBinarySource>(
              key: const Key('request-editor-binary-source'),
              initialValue: _binarySource,
              decoration: const InputDecoration(
                labelText: '二进制来源',
                border: OutlineInputBorder(),
              ),
              items: DebugBinarySource.values
                  .map(
                    (source) => DropdownMenuItem<DebugBinarySource>(
                      value: source,
                      child: Text(source.wire),
                    ),
                  )
                  .toList(),
              onChanged: (value) {
                if (value == null) return;
                setState(() {
                  _binarySource = value;
                  _dirty = true;
                });
              },
            ),
          ],
          const SizedBox(height: AppSpacing.md),
          AppEditorToolbar(
            controller: _body,
            onFormat: isJson ? _formatBodyJson : null,
          ),
          if (_bodyError != null)
            Padding(
              padding: AppSpacing.onlyTopXS,
              child: Text(
                _bodyError!,
                key: const Key('request-editor-body-format-error'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
          const SizedBox(height: AppSpacing.sm),
          Expanded(
            child: TextField(
              key: const Key('request-editor-body'),
              controller: _body,
              maxLines: null,
              expands: true,
              textAlignVertical: TextAlignVertical.top,
              decoration: InputDecoration(
                hintText: _bodyHintText(),
                border: const OutlineInputBorder(),
              ),
              onChanged: (_) {
                setState(() {
                  _dirty = true;
                  _bodyError = null;
                });
              },
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
          _authField(
            key: const Key('request-editor-auth-user'),
            fieldKey: _authUserFieldKey,
            controller: _authUser,
            label: '用户名',
          ),
          _authField(
            key: const Key('request-editor-auth-pass'),
            fieldKey: _authPassFieldKey,
            controller: _authPass,
            label: '密码',
          ),
        ] else if (_authType == DebugAuthType.bearer)
          _authField(
            key: const Key('request-editor-auth-token'),
            fieldKey: _authTokenFieldKey,
            controller: _authToken,
            label: 'Token',
            mode: AppEditableFieldMode.sheet,
          )
        else if (_authType == DebugAuthType.apiKey) ...[
          _authField(
            key: const Key('request-editor-auth-key-name'),
            fieldKey: _authKeyNameFieldKey,
            controller: _authKeyName,
            label: 'Key 名',
          ),
          _authField(
            key: const Key('request-editor-auth-key-value'),
            fieldKey: _authKeyValueFieldKey,
            controller: _authKeyValue,
            label: 'Key 值',
            mode: AppEditableFieldMode.sheet,
          ),
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

  Widget _authField({
    required Key key,
    required GlobalKey<AppEditableFieldState> fieldKey,
    required TextEditingController controller,
    required String label,
    AppEditableFieldMode mode = AppEditableFieldMode.inline,
  }) {
    return Padding(
      key: key,
      padding: AppSpacing.onlyBottomMD,
      child: AppEditableField(
        key: fieldKey,
        controller: controller,
        mode: mode,
        label: label,
        textInputAction: TextInputAction.next,
        toolbarBuilder: mode == AppEditableFieldMode.sheet
            ? _sheetToolbar(fieldKey: fieldKey)
            : null,
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
            // 保存 / 另存为 / 导出 cURL 收进溢出菜单，发送保持唯一主操作。
            PopupMenuButton<String>(
              key: const Key('request-editor-more'),
              tooltip: '更多',
              icon: const Icon(TablerIcons.dots),
              onSelected: (value) {
                switch (value) {
                  case 'save':
                    _save();
                  case 'save-as':
                    _saveAs();
                  case 'export-curl':
                    _exportCurl();
                }
              },
              itemBuilder: (_) => const <PopupMenuEntry<String>>[
                PopupMenuItem<String>(
                  key: Key('request-editor-save'),
                  value: 'save',
                  child: Text('保存'),
                ),
                PopupMenuItem<String>(
                  key: Key('request-editor-save-as'),
                  value: 'save-as',
                  child: Text('另存为'),
                ),
                PopupMenuItem<String>(
                  key: Key('request-editor-export-curl'),
                  value: 'export-curl',
                  child: Text('导出 cURL'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 键值编辑行（参数 / 头 / Cookie 共用）。
class _KvRow {
  _KvRow({
    required this.id,
    String name = '',
    String value = '',
    this.enabled = true,
  })  : nameCtrl = TextEditingController(text: name),
        valueCtrl = TextEditingController(text: value);

  /// 稳定唯一 id：列表重排 / 协调时按它复用行对象（保留 controller 与焦点）。
  final String id;

  final TextEditingController nameCtrl;
  final TextEditingController valueCtrl;
  final GlobalKey<AppEditableFieldState> nameFieldKey =
      GlobalKey<AppEditableFieldState>();
  final GlobalKey<AppEditableFieldState> valueFieldKey =
      GlobalKey<AppEditableFieldState>();
  bool enabled;

  void dispose() {
    nameCtrl.dispose();
    valueCtrl.dispose();
  }
}

/// 批量编辑解析出的单行草稿。
class _KvDraft {
  const _KvDraft(this.name, this.value);

  final String name;
  final String value;
}

/// 批量编辑弹层：多行 `key: value` / `key=value` → 行列表。
///
/// 内容自带 controller 生命周期，故用独立 StatefulWidget（弹层退场动画结束后
/// 才随 route 释放，避免提前 dispose 被退场帧引用）。
class _KvBulkEditSheet extends StatefulWidget {
  const _KvBulkEditSheet();

  @override
  State<_KvBulkEditSheet> createState() => _KvBulkEditSheetState();
}

class _KvBulkEditSheetState extends State<_KvBulkEditSheet> {
  final TextEditingController _input = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _confirm() {
    final parsed = _parseKvLines(_input.text);
    if (parsed == null) {
      setState(() => _error = '存在无法解析的行，请使用 key: value 或 key=value');
      return;
    }
    Navigator.of(context).pop(parsed);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AppSheetScaffold(
      title: '批量编辑',
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: const Key('request-editor-kv-bulk-input'),
            controller: _input,
            minLines: 5,
            maxLines: null,
            autofocus: true,
            decoration: const InputDecoration(
              hintText: 'key: value\nkey2=value2',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
          ),
          if (_error != null)
            Padding(
              padding: AppSpacing.onlyTopXS,
              child: Text(
                _error!,
                key: const Key('request-editor-kv-bulk-error'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
        ],
      ),
      actions: [
        TextButton(
          key: const Key('request-editor-kv-bulk-cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('request-editor-kv-bulk-confirm'),
          onPressed: _confirm,
          child: const Text('导入'),
        ),
      ],
    );
  }
}

/// 解析多行键值文本；任一非空行缺少 `:` / `=` 分隔或键为空时返回 `null`。
List<_KvDraft>? _parseKvLines(String text) {
  final result = <_KvDraft>[];
  for (final raw in text.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    final index = _firstKvSeparator(line);
    if (index == null) return null;
    final name = line.substring(0, index).trim();
    if (name.isEmpty) return null;
    result.add(_KvDraft(name, line.substring(index + 1).trim()));
  }
  return result;
}

/// 行内第一个 `:` 或 `=` 的位置；都没有返回 `null`。
int? _firstKvSeparator(String line) {
  final colon = line.indexOf(':');
  final equals = line.indexOf('=');
  if (colon < 0) return equals < 0 ? null : equals;
  if (equals < 0) return colon;
  return colon < equals ? colon : equals;
}
