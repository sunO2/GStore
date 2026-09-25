/// 「请求调试」响应查看器（plan todo 32）。
///
/// 消费 [DebugResponse]（todo 26）展示一次发送的结果：
/// - 头部：状态码 / 耗时 / 大小 + `格式化 / 原始` 切换 + `复制` + `保存为改写响应`；
/// - 分段：`头 / Body / Cookie / 原始`（复用 [AppSegmentedButton]）；
/// - Body：按 `Content-Type` 渲染 JSON / XML / HTML / 文本，非文本走安全占位；
/// - Cookie：名称 / 值 / 域 / 过期 表格；
/// - 大 Body **分块**渲染（首屏只建首个分块的文本，超出经「展开更多」续载），
///   避免一次性布局几十万字符而卡死 UI。
///
/// 设计约束：颜色 / 字号全取主题令牌，分段用 [AppSegmentedButton]，弹层走
/// [AppDialogs] 统一底部弹层，零硬编码颜色 / 字号。
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';

import 'package:gstore/core/design/app_components.dart';
import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/design/app_radius.dart';
import 'package:gstore/core/design/app_spacing.dart';
import 'package:gstore/core/design/app_typography.dart';
import 'package:gstore/core/request_debug/request_debug.dart';
import 'package:gstore/core/utils/unit.dart';

/// 响应体的语义类型（由 `Content-Type` 推断）。
enum ResponseBodyKind {
  json,
  xml,
  html,
  text,

  /// 二进制 / 非文本（安全占位，不渲染原始字节）。
  binary,
}

/// 查看器内部的分段（头 / Body / Cookie / 原始）。
enum ResponseViewerTab { headers, body, cookies, raw }

/// 格式化开关。
enum ResponseBodyFormat { formatted, raw }

/// 单次响应查看器。
class ResponseViewer extends StatefulWidget {
  const ResponseViewer({
    super.key,
    required this.response,
    this.method,
    this.url,
    this.onSaveAsRewrite,
  });

  /// 待展示的响应快照。
  final DebugResponse response;

  /// 请求方法（保存为改写规则时使用）。
  final String? method;

  /// 请求 URL（保存为改写规则时使用；为空则禁用该动作）。
  final String? url;

  /// `保存为改写响应` 的落地回调；返回门面结果（失败已在 UI 提示）。
  final Future<CaptureRulesResult<DebugRewriteRule>> Function(
    DebugRewriteRule rule,
  )? onSaveAsRewrite;

  /// 单个文本分块的字符上限（超出即折叠，避免一次性布局超长文本）。
  static const int chunkChars = 20000;

  /// JSON 高亮 / 折叠树的体量上限；超过则退回分块纯文本渲染。
  static const int maxJsonHighlightChars = 256 * 1024;

  @override
  State<ResponseViewer> createState() => _ResponseViewerState();
}

class _ResponseViewerState extends State<ResponseViewer> {
  ResponseViewerTab _tab = ResponseViewerTab.body;
  ResponseBodyFormat _format = ResponseBodyFormat.formatted;
  bool _saving = false;

  DebugResponse get _response => widget.response;

  @override
  void didUpdateWidget(ResponseViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 换了一次响应（重发）：回到 Body 默认态。分块 / 搜索 / 折叠由 Body pane 自持，
    // 会因 pane 的文本 / 格式变化在其 didUpdateWidget 中重置。
    if (!identical(oldWidget.response, widget.response)) {
      _tab = ResponseViewerTab.body;
      _format = ResponseBodyFormat.formatted;
    }
  }

  // ==================== 纯逻辑（可单测） ====================

  /// 取 `Content-Type` 头的首个值（大小写不敏感）。
  String? get _contentType {
    for (final entry in _response.headers.entries) {
      if (entry.key.toLowerCase() == 'content-type') {
        return entry.value.isEmpty ? null : entry.value.first;
      }
    }
    return null;
  }

  /// Body 的语义类型：`Content-Type` 优先，其次按内容猜（含 NUL 即二进制）。
  ResponseBodyKind get _bodyKind {
    final kind = classifyContentType(_contentType);
    if (kind != null) return kind;
    final text = _response.bodyText;
    if (text.isEmpty && _response.bodyBytes.isNotEmpty) {
      return ResponseBodyKind.binary;
    }
    return isLikelyBinaryText(text)
        ? ResponseBodyKind.binary
        : ResponseBodyKind.text;
  }

  /// 按开关 / 类型得到用于展示与复制的 Body 文本。
  String get _displayText => _displayResponseBodyText(
        rawText: _response.bodyText,
        bodyKind: _bodyKind,
        format: _format,
      );

  /// Cookie 行的展示模型（含从 `Set-Cookie` 还原的过期信息）。
  List<ResponseCookieRow> get _cookieRows {
    final setCookie = <String>[];
    for (final entry in _response.headers.entries) {
      if (entry.key.toLowerCase() == 'set-cookie') {
        setCookie.addAll(entry.value);
      }
    }
    return _response.cookies
        .map(
          (c) => ResponseCookieRow(
            cookie: c,
            expires: cookieExpiryLabel(c.name, setCookie),
          ),
        )
        .toList();
  }

  // ==================== 动作 ====================

  Future<void> _copyBody() async {
    final text = _bodyKind == ResponseBodyKind.binary
        ? _response.bodyText
        : _displayText;
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    AppDialogs.showSuccess('已复制响应体');
  }

  Future<void> _saveAsRewrite() async {
    final callback = widget.onSaveAsRewrite;
    final url = widget.url;
    if (callback == null || url == null || url.isEmpty || _saving) return;
    final confirmed = await AppDialogs.showConfirmSheet(
      title: '保存为改写响应？',
      message: '将把当前响应保存为**全局**改写规则：命中精确 URL 的请求会被此响应替换。'
          '规则仅作用于 h1/h2 请求，WebSocket 帧不支持改写。',
      confirmText: '保存',
    );
    if (confirmed != true || !mounted) return;
    setState(() => _saving = true);
    final rule = DebugRewriteRule(
      id: generateDebugId('rule'),
      method: widget.method,
      url: url,
      kind: DebugRewriteKind.replaceResponse,
      statusCode: _response.statusCode,
      respHeaders: _response.headers.entries
          .expand(
            (e) => e.value.map(
              (v) => DebugHeader(name: e.key, value: v),
            ),
          )
          .toList(),
      respBody: _response.bodyText,
      remark: '来自请求调试响应',
    );
    final result = await callback(rule);
    if (!mounted) return;
    setState(() => _saving = false);
    if (result.isSuccess) {
      AppDialogs.showSuccess('已保存为改写响应');
    } else {
      AppDialogs.showError(result.error ?? '保存失败');
    }
  }

  // ==================== 构建 ====================

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildHeader(context),
        const Divider(height: 1),
        Expanded(child: _buildTabBody(context)),
      ],
    );
  }

  Widget _buildHeader(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: AppSpacing.allLG,
      child: Wrap(
        spacing: AppSpacing.sm,
        runSpacing: AppSpacing.sm,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          _buildStatusBadge(context),
          Text(
            formatDuration(_response.durationMs),
            key: const Key('response-duration'),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          Text(
            byteSize(_response.sizeBytes),
            key: const Key('response-size'),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          AppPillToggle<ResponseBodyFormat>(
            value: _format,
            segments: const <AppSegment<ResponseBodyFormat>>[
              AppSegment(
                value: ResponseBodyFormat.formatted,
                label: '格式化',
                key: Key('response-format-formatted'),
              ),
              AppSegment(
                value: ResponseBodyFormat.raw,
                label: '原始',
                key: Key('response-format-raw'),
              ),
            ],
            onChanged: (value) => setState(() {
              _format = value;
            }),
          ),
          IconButton(
            key: const Key('response-copy'),
            tooltip: '复制',
            icon: const Icon(TablerIcons.copy),
            onPressed: _copyBody,
          ),
          TextButton.icon(
            key: const Key('response-save-rewrite'),
            onPressed: widget.onSaveAsRewrite == null ||
                    (widget.url ?? '').isEmpty ||
                    _saving
                ? null
                : _saveAsRewrite,
            icon: const Icon(TablerIcons.device_floppy),
            label: const Text('保存为改写响应'),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusBadge(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final color = _statusColor(scheme);
    return Container(
      padding: AppSpacing.horizontalSM_verticalXS,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: AppRadius.allSM,
      ),
      child: Text(
        '${_response.statusCode}',
        key: const Key('request-editor-response-status'),
        style: theme.textTheme.titleMedium?.copyWith(
          color: color,
          fontWeight: AppTypography.weightSemiBold,
        ),
      ),
    );
  }

  Color _statusColor(ColorScheme scheme) {
    if (_response.hasError || _response.statusCode >= 400) {
      return scheme.error;
    }
    if (_response.isSuccess) return scheme.primary;
    return scheme.onSurfaceVariant;
  }

  Widget _buildTabBody(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: AppSpacing.onlyHorizontalLG,
          child: AppTabBar<ResponseViewerTab>(
            value: _tab,
            segments: const <AppSegment<ResponseViewerTab>>[
              AppSegment(
                value: ResponseViewerTab.headers,
                label: '头',
                key: Key('response-tab-headers'),
              ),
              AppSegment(
                value: ResponseViewerTab.body,
                label: 'Body',
                key: Key('response-tab-body'),
              ),
              AppSegment(
                value: ResponseViewerTab.cookies,
                label: 'Cookie',
                key: Key('response-tab-cookies'),
              ),
              AppSegment(
                value: ResponseViewerTab.raw,
                label: '原始',
                key: Key('response-tab-raw'),
              ),
            ],
            onChanged: (value) => setState(() {
              _tab = value;
            }),
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        Expanded(child: _buildTabContent(context)),
      ],
    );
  }

  Widget _buildTabContent(BuildContext context) {
    if (_response.hasError && _response.bodyText.isEmpty) {
      return _buildError(context);
    }
    switch (_tab) {
      case ResponseViewerTab.headers:
        return _buildHeaders(context);
      case ResponseViewerTab.body:
        return _buildBody(context);
      case ResponseViewerTab.cookies:
        return _buildCookies(context);
      case ResponseViewerTab.raw:
        return _buildRaw(context);
    }
  }

  Widget _buildError(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: AppSpacing.allLG,
      children: [
        Text(
          _response.error ?? '请求失败',
          key: const Key('response-error'),
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.error,
          ),
        ),
      ],
    );
  }

  Widget _buildHeaders(BuildContext context) {
    final theme = Theme.of(context);
    final rows = <MapEntry<String, String>>[];
    _response.headers.forEach((name, values) {
      if (values.isEmpty) {
        rows.add(MapEntry<String, String>(name, ''));
      } else {
        for (final value in values) {
          rows.add(MapEntry<String, String>(name, value));
        }
      }
    });
    if (rows.isEmpty) {
      return _buildEmptyState(context, '无响应头');
    }
    return ListView.builder(
      padding: AppSpacing.allLG,
      itemCount: rows.length,
      itemBuilder: (context, index) {
        final row = rows[index];
        return Padding(
          key: Key('response-header-${row.key}-$index'),
          padding: AppSpacing.onlyVerticalXS,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 2,
                child: Text(
                  row.key,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontWeight: AppTypography.weightMedium,
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                flex: 3,
                child: SelectableText(
                  row.value,
                  style: AppTypography.code,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildBody(BuildContext context) {
    return _ResponseBodyPane(
      key: const ValueKey<String>('response-body-pane'),
      rawText: _response.bodyText,
      bodyKind: _bodyKind,
      format: _format,
      sizeBytes: _response.sizeBytes,
      keyPrefix: 'response-body',
      onFullscreen: _openFullScreenBody,
    );
  }

  Widget _buildRaw(BuildContext context) {
    return _ResponseBodyPane(
      key: const ValueKey<String>('response-raw-pane'),
      rawText: _response.bodyText,
      bodyKind: _bodyKind,
      format: _format,
      sizeBytes: _response.sizeBytes,
      keyPrefix: 'response-raw',
      forceRaw: true,
    );
  }

  /// 打开全屏响应体查看（搜索仅在此处提供）。
  Future<void> _openFullScreenBody() async {
    await Navigator.of(context, rootNavigator: false).push<void>(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => _ResponseBodyFullScreen(
          rawText: _response.bodyText,
          bodyKind: _bodyKind,
          format: _format,
          sizeBytes: _response.sizeBytes,
        ),
      ),
    );
  }

  Widget _buildCookies(BuildContext context) {
    final theme = Theme.of(context);
    final rows = _cookieRows;
    if (rows.isEmpty) {
      return _buildEmptyState(context, '无 Cookie');
    }
    return ListView(
      padding: AppSpacing.allLG,
      children: [
        _cookieHeaderRow(context, theme),
        const Divider(height: 1),
        for (var i = 0; i < rows.length; i++) _cookieRow(context, theme, rows[i], i),
      ],
    );
  }

  Widget _cookieHeaderRow(BuildContext context, ThemeData theme) {
    final style = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
      fontWeight: AppTypography.weightSemiBold,
    );
    return Padding(
      padding: AppSpacing.onlyVerticalXS,
      child: Row(
        children: [
          Expanded(flex: 2, child: Text('名称', style: style)),
          Expanded(flex: 3, child: Text('值', style: style)),
          Expanded(flex: 2, child: Text('域', style: style)),
          Expanded(flex: 2, child: Text('过期', style: style)),
        ],
      ),
    );
  }

  Widget _cookieRow(
    BuildContext context,
    ThemeData theme,
    ResponseCookieRow row,
    int index,
  ) {
    final base = theme.textTheme.bodySmall;
    return Padding(
      key: Key('response-cookie-row-${row.cookie.name}-$index'),
      padding: AppSpacing.onlyVerticalXS,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 2,
            child: Text(
              row.cookie.name,
              key: Key('response-cookie-${row.cookie.name}-name'),
              style: base?.copyWith(fontWeight: AppTypography.weightMedium),
            ),
          ),
          Expanded(
            flex: 3,
            child: SelectableText(
              row.cookie.value,
              key: Key('response-cookie-${row.cookie.name}-value'),
              style: AppTypography.code,
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              row.cookie.domain ?? '—',
              key: Key('response-cookie-${row.cookie.name}-domain'),
              style: base,
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              row.expires,
              key: Key('response-cookie-${row.cookie.name}-expires'),
              style: base,
            ),
          ),
        ],
      ),
    );
  }
}

/// Body 渲染面板：行内 Body / 原始分段 / 全屏查看共用。
///
/// 自持分块可见字符数、完整文本搜索状态与 JSON 折叠状态。[showSearch] 决定是否
/// 渲染搜索条（仅全屏为真）；[onFullscreen] 非空时渲染「全屏查看」按钮。
/// 搜索命中项基于**完整** bodyText 定位，命中位于当前分块外时仍会展开可见范围。
class _ResponseBodyPane extends StatefulWidget {
  const _ResponseBodyPane({
    super.key,
    required this.rawText,
    required this.bodyKind,
    required this.format,
    required this.sizeBytes,
    required this.keyPrefix,
    this.showSearch = false,
    this.forceRaw = false,
    this.onFullscreen,
    this.scale = 1.0,
  });

  final String rawText;
  final ResponseBodyKind bodyKind;
  final ResponseBodyFormat format;
  final int sizeBytes;

  /// 内容控件 key 前缀（`<prefix>-tree` / `-gutter` / `-collapse-<id>` /
  /// `-text` / `-more` / `-counter` / `-search` / `-search-input` / `-search-status`）。
  final String keyPrefix;

  /// 是否渲染搜索条（仅全屏为真）。
  final bool showSearch;

  /// 原始分段：始终按原文分块，不做 JSON 树 / 二进制占位 / 类型美化。
  final bool forceRaw;

  /// 非空时渲染「全屏查看」按钮并作为其动作。
  final VoidCallback? onFullscreen;

  /// 正文内容缩放系数（仅全屏页可 != 1.0；行内 Body / Raw 固定 1.0）。
  final double scale;

  @override
  State<_ResponseBodyPane> createState() => _ResponseBodyPaneState();
}

class _ResponseBodyPaneState extends State<_ResponseBodyPane> {
  /// 当前已展开的字符数（分块续载）。
  int _visibleChars = ResponseViewer.chunkChars;

  /// Body 内搜索：输入控制器 + 命中状态（命中项基于**完整**文本计算）。
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  int? _searchOffset;
  bool _searchMiss = false;

  /// 已折叠的 JSON 容器区间 id（== 开括号所在行号）。
  final Set<int> _collapsed = <int>{};

  @override
  void didUpdateWidget(_ResponseBodyPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 文本 / 类型 / 格式变化（换响应、切格式化）→ 重置分块 / 搜索 / 折叠。
    if (oldWidget.rawText != widget.rawText ||
        oldWidget.bodyKind != widget.bodyKind ||
        oldWidget.format != widget.format ||
        oldWidget.forceRaw != widget.forceRaw) {
      _visibleChars = ResponseViewer.chunkChars;
      _clearSearch();
      _collapsed.clear();
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  // ==================== 纯逻辑（可单测） ====================

  /// 按开关 / 类型得到用于展示的 Body 文本。
  String get _displayText => _displayResponseBodyText(
        rawText: widget.rawText,
        bodyKind: widget.bodyKind,
        format: widget.format,
        forceRaw: widget.forceRaw,
      );

  /// 搜索所依据的完整文本（JSON / XML 走完整美化文本，其余走原始 bodyText）。
  String get _searchSourceText => _searchResponseBodySource(
        rawText: widget.rawText,
        bodyKind: widget.bodyKind,
        format: widget.format,
        forceRaw: widget.forceRaw,
      );

  /// JSON 高亮 / 折叠树是否启用（小体量、合法、格式化态的 JSON）。
  bool get _jsonTreeActive =>
      !widget.forceRaw &&
      widget.bodyKind == ResponseBodyKind.json &&
      widget.format == ResponseBodyFormat.formatted &&
      widget.rawText.length <= ResponseViewer.maxJsonHighlightChars &&
      tryPrettyJson(widget.rawText) != null;

  // ==================== 缩放（字号 / 行高同一来源） ====================

  /// 缩放后的正文字号（JSON / 纯文本 / gutter 行号共用）。
  double get _contentFontSize =>
      (AppTypography.code.fontSize ?? AppTypography.sizeSM) * widget.scale;

  /// 缩放后的正文行高 = 字号 × 行高倍数。
  double get _contentLineHeight =>
      (AppTypography.code.fontSize ?? AppTypography.sizeSM) *
      (AppTypography.code.height ?? AppTypography.heightNormal) *
      widget.scale;

  /// gutter 每行占位高度：文本引擎按 `round(fontSize × height)` 排版行盒，
  /// gutter 必须取同一取整值，否则非整数缩放（如 1.25 → 26.25）会逐行累积错位。
  double get _gutterLineHeight => _contentLineHeight.roundToDouble();

  /// 缩放后的代码样式：JSON 内容 / token / gutter 行号 / 纯文本共用。
  TextStyle get _scaledCodeStyle => AppTypography.code.copyWith(
        fontSize: _contentFontSize,
        height: AppTypography.code.height ?? AppTypography.heightNormal,
      );

  /// 清空搜索状态（切换格式 / 换文本时调用）。
  void _clearSearch() {
    _searchController.clear();
    _searchQuery = '';
    _searchOffset = null;
    _searchMiss = false;
  }

  /// 搜索输入变化：在完整文本上定位首个命中；分块纯文本路径下展开可见文本。
  void _onSearchChanged(String query) {
    setState(() {
      _searchQuery = query;
      if (query.isEmpty) {
        _searchOffset = null;
        _searchMiss = false;
        return;
      }
      final index = _searchSourceText.indexOf(query);
      if (index < 0) {
        _searchOffset = null;
        _searchMiss = true;
        return;
      }
      _searchOffset = index;
      _searchMiss = false;
      // 仅分块纯文本路径需要按命中位置扩展可见范围；JSON 高亮树整体渲染。
      if (!_jsonTreeActive) {
        final end = index + query.length;
        if (end > _visibleChars) _visibleChars = end;
      }
    });
  }

  // ==================== 构建 ====================

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.showSearch) _buildSearchBar(context),
        if (widget.onFullscreen != null) _buildFullscreenBar(context),
        Expanded(child: _buildContent(context)),
      ],
    );
  }

  /// 行内 Body 的「全屏查看」入口（搜索只在全屏存在）。
  Widget _buildFullscreenBar(BuildContext context) {
    return Padding(
      padding: AppSpacing.onlyHorizontalLG,
      child: Align(
        alignment: Alignment.centerRight,
        child: TextButton.icon(
          key: Key('${widget.keyPrefix}-fullscreen'),
          onPressed: widget.onFullscreen,
          icon: const Icon(Icons.open_in_full, size: AppTypography.iconSM),
          label: const Text('全屏查看'),
        ),
      ),
    );
  }

  Widget _buildContent(BuildContext context) {
    if (!widget.forceRaw && widget.bodyKind == ResponseBodyKind.binary) {
      return _buildBinary(context);
    }
    final text = _displayText;
    if (text.isEmpty) {
      return _buildEmptyState(context, '响应体为空');
    }
    // JSON 高亮 / 折叠树仅在小体量下启用；超限或非法 JSON 退回分块纯文本。
    final canHighlight = !widget.forceRaw &&
        widget.bodyKind == ResponseBodyKind.json &&
        widget.format == ResponseBodyFormat.formatted &&
        widget.rawText.length <= ResponseViewer.maxJsonHighlightChars;
    if (_jsonTreeActive) {
      return _buildJsonTree(context, tryPrettyJson(widget.rawText)!);
    }
    return _buildChunkedText(
      context,
      text,
      keyPrefix: widget.keyPrefix,
      note: canHighlight ? 'JSON 解析失败，已按原文展示' : null,
    );
  }

  /// 分块渲染：首屏只建前 [ResponseViewer.chunkChars] 个字符的文本，
  /// 超出部分经顶部的「展开更多」按钮按块续载，避免一次性布局超长文本。
  Widget _buildChunkedText(
    BuildContext context,
    String text, {
    required String keyPrefix,
    required String? note,
  }) {
    final theme = Theme.of(context);
    final total = text.length;
    final visible = _visibleChars >= total ? total : _visibleChars;
    final shown = text.substring(0, visible);
    final remaining = total - visible;
    return ListView(
      padding: AppSpacing.allLG,
      children: [
        // 控制条在文本**之前**：超长文本会占满视口，按钮若在其后将被
        // ListView 懒加载跳过而不可达。
        if (remaining > 0)
          Padding(
            padding: AppSpacing.onlyBottomMD,
            child: Row(
              children: [
                Icon(
                  TablerIcons.chevron_down,
                  size: AppTypography.iconMD,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: AppSpacing.xs),
                Expanded(
                  child: Text(
                    '已显示 $visible / $total 字符',
                    key: Key('$keyPrefix-counter'),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                OutlinedButton(
                  key: Key('$keyPrefix-more'),
                  onPressed: () => setState(() {
                    _visibleChars = visible + ResponseViewer.chunkChars;
                  }),
                  child: Text('展开更多（剩余 $remaining 字符）'),
                ),
              ],
            ),
          ),
        if (note != null)
          Padding(
            padding: AppSpacing.onlyBottomSM,
            child: Text(
              note,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        _buildPlainText(context, shown, Key('$keyPrefix-text')),
      ],
    );
  }

  /// 纯文本控件；搜索命中时以 `Text.rich` 高亮命中片段。
  Widget _buildPlainText(BuildContext context, String shown, Key key) {
    final scheme = Theme.of(context).colorScheme;
    final query = _searchQuery;
    final index =
        _searchOffset == null || query.isEmpty ? -1 : shown.indexOf(query);
    if (index < 0) {
      return SelectableText(shown, key: key, style: _scaledCodeStyle);
    }
    final end = index + query.length;
    return SelectableText.rich(
      TextSpan(
        children: [
          TextSpan(text: shown.substring(0, index)),
          TextSpan(
            text: shown.substring(index, end),
            style: TextStyle(backgroundColor: scheme.primaryContainer),
          ),
          TextSpan(text: shown.substring(end)),
        ],
      ),
      key: key,
      style: _scaledCodeStyle,
    );
  }

  /// Body 内搜索条（仅全屏渲染）。
  Widget _buildSearchBar(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      key: Key('${widget.keyPrefix}-search'),
      padding: AppSpacing.onlyBottomMD,
      child: Row(
        children: [
          Expanded(
            child: TextField(
              key: Key('${widget.keyPrefix}-search-input'),
              controller: _searchController,
              style: theme.textTheme.bodySmall,
              decoration: InputDecoration(
                isDense: true,
                hintText: '在完整响应体中搜索',
                prefixIcon: const Icon(
                  TablerIcons.search,
                  size: AppTypography.iconSM,
                ),
                suffixIcon: _searchQuery.isEmpty
                    ? null
                    : IconButton(
                        tooltip: '清除',
                        icon: const Icon(
                          TablerIcons.x,
                          size: AppTypography.iconSM,
                        ),
                        onPressed: () => setState(_clearSearch),
                      ),
                border: const OutlineInputBorder(borderRadius: AppRadius.allSM),
              ),
              onChanged: _onSearchChanged,
              onSubmitted: _onSearchChanged,
            ),
          ),
          if (_searchQuery.isNotEmpty)
            Padding(
              padding: AppSpacing.onlyLeftMD,
              child: Text(
                _searchMiss ? '无匹配' : '已定位',
                key: Key('${widget.keyPrefix}-search-status'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: _searchMiss ? scheme.error : scheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// JSON 高亮 / 折叠树：行号 gutter + 无换行横向滚动 + 可折叠容器 + 搜索高亮。
  Widget _buildJsonTree(BuildContext context, String pretty) {
    final scheme = Theme.of(context).colorScheme;
    final lines = pretty.split('\n');
    final regions = jsonFoldRegions(lines);
    final regionById = <int, JsonFoldRegion>{
      for (final region in regions) region.id: region,
    };
    final hidden = List<bool>.filled(lines.length, false);
    for (final id in _collapsed) {
      final region = regionById[id];
      if (region == null) continue;
      for (var i = region.openLine + 1;
          i <= region.closeLine && i < lines.length;
          i++) {
        hidden[i] = true;
      }
    }
    final visibleLines = <int>[
      for (var i = 0; i < lines.length; i++)
        if (!hidden[i]) i,
    ];

    final spans = <InlineSpan>[];
    for (var v = 0; v < visibleLines.length; v++) {
      final i = visibleLines[v];
      final highlight =
          _searchQuery.isNotEmpty && lines[i].contains(_searchQuery);
      spans.addAll(_jsonLineSpans(lines[i], highlight, scheme));
      if (v < visibleLines.length - 1) {
        spans.add(const TextSpan(text: '\n'));
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: SingleChildScrollView(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Container(
                key: Key('${widget.keyPrefix}-tree'),
                padding: AppSpacing.allMD,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildJsonGutter(
                      context,
                      lines.length,
                      visibleLines,
                      regionById,
                    ),
                    const SizedBox(width: AppSpacing.md),
                    Text.rich(
                      TextSpan(children: spans),
                      key: Key('${widget.keyPrefix}-json'),
                      style: _scaledCodeStyle.copyWith(color: scheme.onSurface),
                      softWrap: false,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// 行号 + 折叠开关列；与文本行等高等宽，横向滚动时随文本一起移动。
  Widget _buildJsonGutter(
    BuildContext context,
    int lineCount,
    List<int> visibleLines,
    Map<int, JsonFoldRegion> regionById,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final lineHeight = _gutterLineHeight;
    final numberWidth =
        AppSpacing.xs + '$lineCount'.length * AppTypography.sizeXS;
    return Column(
      key: Key('${widget.keyPrefix}-gutter'),
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        for (final i in visibleLines)
          SizedBox(
            height: lineHeight,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                SizedBox(
                  width: AppTypography.iconMD,
                  child: regionById.containsKey(i)
                      ? GestureDetector(
                          key: Key('${widget.keyPrefix}-collapse-$i'),
                          behavior: HitTestBehavior.opaque,
                          onTap: () => setState(() {
                            if (!_collapsed.remove(i)) _collapsed.add(i);
                          }),
                          child: Icon(
                            _collapsed.contains(i)
                                ? TablerIcons.chevron_right
                                : TablerIcons.chevron_down,
                            size: AppTypography.iconSM,
                            color: scheme.onSurfaceVariant,
                          ),
                        )
                      : null,
                ),
                const SizedBox(width: AppSpacing.xs),
                SizedBox(
                  width: numberWidth,
                  child: Text(
                    '${i + 1}',
                    textAlign: TextAlign.right,
                    softWrap: false,
                    style: _scaledCodeStyle.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  /// 单行 JSON 的 token spans（搜索命中时整行加底色）。
  List<InlineSpan> _jsonLineSpans(
    String line,
    bool highlight,
    ColorScheme scheme,
  ) =>
      [
        for (final token in tokenizeJsonLine(line))
          TextSpan(
            text: token.text,
            style: _jsonTokenStyle(scheme, token.kind, highlight),
          ),
      ];

  TextStyle _jsonTokenStyle(
    ColorScheme scheme,
    JsonTokenKind kind,
    bool highlight,
  ) {
    final base = _scaledCodeStyle;
    final style = switch (kind) {
      JsonTokenKind.key => base.copyWith(
          color: scheme.primary,
          fontWeight: AppTypography.weightMedium,
        ),
      JsonTokenKind.string => base.copyWith(color: scheme.tertiary),
      JsonTokenKind.number => base.copyWith(color: scheme.secondary),
      JsonTokenKind.keyword => base.copyWith(color: scheme.error),
      JsonTokenKind.punctuation =>
        base.copyWith(color: scheme.onSurfaceVariant),
      JsonTokenKind.plain => base.copyWith(color: scheme.onSurface),
    };
    return highlight
        ? style.copyWith(
            backgroundColor: scheme.primaryContainer.withValues(alpha: 0.5),
          )
        : style;
  }

  Widget _buildBinary(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return ListView(
      padding: AppSpacing.allLG,
      children: [
        Container(
          key: Key('${widget.keyPrefix}-binary'),
          padding: AppSpacing.allLG,
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest,
            borderRadius: AppRadius.allMD,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(TablerIcons.file_zip, color: scheme.onSurfaceVariant),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '二进制 / 非文本内容',
                      style: theme.textTheme.titleSmall,
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      '${byteSize(widget.sizeBytes)} · 不显示为文本（可点击复制原始预览）',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 全屏响应体查看页：自带 [Scaffold] + [AppBar]，搜索仅在此提供。
///
/// 由行内 Body 的「全屏查看」经 `Navigator.push`（`fullscreenDialog: true`,
/// `rootNavigator: false`）打开；返回后行内 Body 保持不变。AppBar 提供内容
/// 缩放（[response-fullscreen-zoom-*]），缩放系数经 [_ResponseBodyPane.scale]
/// 同因子作用于正文与行号 gutter，保证行号始终对齐。
class _ResponseBodyFullScreen extends StatefulWidget {
  const _ResponseBodyFullScreen({
    required this.rawText,
    required this.bodyKind,
    required this.format,
    required this.sizeBytes,
  });

  final String rawText;
  final ResponseBodyKind bodyKind;
  final ResponseBodyFormat format;
  final int sizeBytes;

  @override
  State<_ResponseBodyFullScreen> createState() =>
      _ResponseBodyFullScreenState();
}

class _ResponseBodyFullScreenState extends State<_ResponseBodyFullScreen> {
  static const double _minScale = 0.75;
  static const double _maxScale = 2.0;
  static const double _scaleStep = 0.25;

  double _scale = 1.0;

  bool get _canZoomOut => _scale > _minScale;
  bool get _canZoomIn => _scale < _maxScale;

  void _zoomIn() {
    if (!_canZoomIn) return;
    final next = _scale + _scaleStep;
    setState(() => _scale = next > _maxScale ? _maxScale : next);
  }

  void _zoomOut() {
    if (!_canZoomOut) return;
    final next = _scale - _scaleStep;
    setState(() => _scale = next < _minScale ? _minScale : next);
  }

  void _resetZoom() => setState(() => _scale = 1.0);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      key: const Key('response-body-fullscreen-view'),
      appBar: AppBar(
        title: const Text('响应体'),
        leading: IconButton(
          key: const Key('response-body-fullscreen-close'),
          tooltip: '返回',
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        actions: [
          IconButton(
            key: const Key('response-fullscreen-zoom-out'),
            tooltip: '缩小',
            icon: const Icon(Icons.zoom_out),
            onPressed: _canZoomOut ? _zoomOut : null,
          ),
          Center(
            child: Text(
              '${(_scale * 100).round()}%',
              key: const Key('response-fullscreen-zoom-level'),
              style: theme.textTheme.labelLarge,
            ),
          ),
          IconButton(
            key: const Key('response-fullscreen-zoom-in'),
            tooltip: '放大',
            icon: const Icon(Icons.zoom_in),
            onPressed: _canZoomIn ? _zoomIn : null,
          ),
          IconButton(
            key: const Key('response-fullscreen-zoom-reset'),
            tooltip: '重置缩放',
            icon: const Icon(Icons.restart_alt),
            onPressed: _resetZoom,
          ),
        ],
      ),
      body: SafeArea(
        child: _ResponseBodyPane(
          rawText: widget.rawText,
          bodyKind: widget.bodyKind,
          format: widget.format,
          sizeBytes: widget.sizeBytes,
          keyPrefix: 'response-fullscreen',
          showSearch: true,
          scale: _scale,
        ),
      ),
    );
  }
}

/// 空态占位（无响应体 / 无响应头 / 无 Cookie）。
Widget _buildEmptyState(BuildContext context, String message) {
  final theme = Theme.of(context);
  return Center(
    child: Text(
      message,
      style: theme.textTheme.bodyMedium?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
    ),
  );
}

/// Body 展示文本：二进制返回空串；原始 / 原文按开关；JSON 小体量美化。
String _displayResponseBodyText({
  required String rawText,
  required ResponseBodyKind bodyKind,
  required ResponseBodyFormat format,
  bool forceRaw = false,
}) {
  if (!forceRaw && bodyKind == ResponseBodyKind.binary) return '';
  if (forceRaw || format == ResponseBodyFormat.raw) return rawText;
  switch (bodyKind) {
    case ResponseBodyKind.json:
      // 超限时不做（昂贵的）整体美化，直接原文分块展示。
      if (rawText.length > ResponseViewer.maxJsonHighlightChars) return rawText;
      return tryPrettyJson(rawText) ?? rawText;
    case ResponseBodyKind.xml:
      return prettyXml(rawText);
    case ResponseBodyKind.html:
    case ResponseBodyKind.text:
    case ResponseBodyKind.binary:
      return rawText;
  }
}

/// 搜索所依据的完整文本：JSON / XML 走（完整）美化文本，其余走原始 bodyText。
///
/// 关键点：搜索永远基于**完整**文本而非当前可见分块，因此命中位于分块外时
/// 仍可被定位并展开。
String _searchResponseBodySource({
  required String rawText,
  required ResponseBodyKind bodyKind,
  required ResponseBodyFormat format,
  bool forceRaw = false,
}) {
  if (!forceRaw && bodyKind == ResponseBodyKind.binary) return '';
  if (forceRaw || format == ResponseBodyFormat.raw) return rawText;
  switch (bodyKind) {
    case ResponseBodyKind.json:
    case ResponseBodyKind.xml:
      return _displayResponseBodyText(
        rawText: rawText,
        bodyKind: bodyKind,
        format: format,
        forceRaw: forceRaw,
      );
    case ResponseBodyKind.html:
    case ResponseBodyKind.text:
    case ResponseBodyKind.binary:
      return rawText;
  }
}

/// Cookie 展示行：模型 + 从 `Set-Cookie` 还原的过期标签。
class ResponseCookieRow {
  const ResponseCookieRow({required this.cookie, required this.expires});

  final DebugCookie cookie;

  /// 过期展示：`Expires` 原文 / `Max-Age N s` / `已过期` / `会话`。
  final String expires;
}

/// 由 `Content-Type` 推断 Body 语义类型；无法识别时返回 `null`（交由内容猜测）。
ResponseBodyKind? classifyContentType(String? contentType) {
  if (contentType == null) return null;
  final mime = contentType.split(';').first.trim().toLowerCase();
  if (mime.isEmpty) return null;
  if (mime == 'application/json' ||
      mime == 'text/json' ||
      mime.endsWith('+json')) {
    return ResponseBodyKind.json;
  }
  if (mime == 'application/xml' ||
      mime == 'text/xml' ||
      mime.endsWith('+xml')) {
    return ResponseBodyKind.xml;
  }
  if (mime == 'text/html' || mime == 'application/xhtml+xml') {
    return ResponseBodyKind.html;
  }
  if (mime.startsWith('text/')) return ResponseBodyKind.text;
  if (mime.startsWith('image/') ||
      mime.startsWith('audio/') ||
      mime.startsWith('video/') ||
      mime.startsWith('font/') ||
      mime == 'application/octet-stream' ||
      mime == 'application/pdf' ||
      mime == 'application/zip' ||
      mime == 'application/gzip' ||
      mime == 'application/x-protobuf' ||
      mime == 'application/wasm') {
    return ResponseBodyKind.binary;
  }
  // 其余 application/* 等按文本兜底（再由内容里的 NUL 判定二进制）。
  return null;
}

/// 文本是否更像二进制（含 NUL 即判二进制）。
bool isLikelyBinaryText(String text) {
  if (text.isEmpty) return false;
  return text.contains('\u0000');
}

/// JSON 词法单元类型（用于高亮着色）。
enum JsonTokenKind { key, string, number, keyword, punctuation, plain }

/// JSON 单行词法单元。
class JsonToken {
  const JsonToken(this.kind, this.text);

  final JsonTokenKind kind;
  final String text;
}

/// 将一行（美化后的）JSON 文本切分为带类型的高亮单元。
///
/// 纯函数、绝不抛异常；无法识别的内容按 [JsonTokenKind.plain] 兜底。
List<JsonToken> tokenizeJsonLine(String line) {
  final tokens = <JsonToken>[];
  var i = 0;
  while (i < line.length) {
    final ch = line[i];
    if (ch == '"') {
      final start = i;
      i++;
      while (i < line.length) {
        if (line[i] == r'\') {
          i += 2;
          continue;
        }
        if (line[i] == '"') {
          i++;
          break;
        }
        i++;
      }
      if (i > line.length) i = line.length;
      final text = line.substring(start, i);
      var j = i;
      while (j < line.length && line[j] == ' ') {
        j++;
      }
      final isKey = j < line.length && line[j] == ':';
      tokens.add(JsonToken(
        isKey ? JsonTokenKind.key : JsonTokenKind.string,
        text,
      ));
      continue;
    }
    if (ch == ' ' || ch == '\t') {
      final start = i;
      while (i < line.length && (line[i] == ' ' || line[i] == '\t')) {
        i++;
      }
      tokens.add(JsonToken(JsonTokenKind.plain, line.substring(start, i)));
      continue;
    }
    if (ch == '-' || _isDigit(ch)) {
      final start = i;
      i++;
      while (i < line.length && _isNumberPart(line[i])) {
        i++;
      }
      tokens.add(JsonToken(JsonTokenKind.number, line.substring(start, i)));
      continue;
    }
    final keyword = _keywordAt(line, i);
    if (keyword != null) {
      tokens.add(JsonToken(JsonTokenKind.keyword, keyword));
      i += keyword.length;
      continue;
    }
    if ('{}[],:'.contains(ch)) {
      tokens.add(JsonToken(JsonTokenKind.punctuation, ch));
      i++;
      continue;
    }
    tokens.add(JsonToken(JsonTokenKind.plain, ch));
    i++;
  }
  return tokens;
}

bool _isDigit(String ch) {
  final code = ch.codeUnitAt(0);
  return code >= 0x30 && code <= 0x39;
}

bool _isNumberPart(String ch) {
  if (_isDigit(ch)) return true;
  return ch == '.' || ch == 'e' || ch == 'E' || ch == '+' || ch == '-';
}

String? _keywordAt(String line, int index) {
  const keywords = <String>['true', 'false', 'null'];
  for (final keyword in keywords) {
    if (line.startsWith(keyword, index)) return keyword;
  }
  return null;
}

/// JSON 中可折叠的容器区间（对象 / 数组）。
class JsonFoldRegion {
  const JsonFoldRegion({
    required this.id,
    required this.openLine,
    required this.closeLine,
  });

  /// 折叠 id（== 开括号所在行号，稳定且便于测试）。
  final int id;

  /// 开括号所在行号。
  final int openLine;

  /// 对应闭括号所在行号。
  final int closeLine;
}

/// 扫描美化后的 JSON 行，返回每个容器（对象 / 数组）的可折叠区间。
///
/// 空容器（`{}` / `[]` 单行）不产生区间。绝不抛异常。
List<JsonFoldRegion> jsonFoldRegions(List<String> lines) {
  final regions = <JsonFoldRegion>[];
  final stack = <int>[];
  for (var i = 0; i < lines.length; i++) {
    final trimmed = lines[i].trim();
    if (trimmed.isEmpty) continue;
    if (trimmed.startsWith('}') || trimmed.startsWith(']')) {
      if (stack.isNotEmpty) {
        final open = stack.removeLast();
        regions.add(
          JsonFoldRegion(id: open, openLine: open, closeLine: i),
        );
      }
      continue;
    }
    if (trimmed.endsWith('{') || trimmed.endsWith('[')) {
      stack.add(i);
    }
  }
  return regions;
}

/// JSON 美化；解析失败返回 `null`（调用方回退原文）。
String? tryPrettyJson(String raw) {
  if (raw.isEmpty) return null;
  try {
    final decoded = jsonDecode(raw);
    return const JsonEncoder.withIndent('  ').convert(decoded);
  } catch (_) {
    return null;
  }
}

/// 轻量 XML 美化（仅按标签缩进；混合内容可能不完美，但绝不抛异常）。
String prettyXml(String raw) =>
    raw.isEmpty ? raw : _prettyXmlImpl(raw);

String _prettyXmlImpl(String input) {
  final buffer = StringBuffer();
  final token = RegExp(r'<[^>]+>|[^<]+');
  var depth = 0;
  for (final match in token.allMatches(input)) {
    final text = match.group(0)!;
    if (text.startsWith('</')) {
      if (depth > 0) depth--;
      buffer.writeln('${'  ' * depth}$text');
    } else if (text.startsWith('<?') || text.startsWith('<!')) {
      buffer.writeln('${'  ' * depth}$text');
    } else if (text.startsWith('<')) {
      final selfClosing = text.endsWith('/>');
      buffer.writeln('${'  ' * depth}$text');
      if (!selfClosing) depth++;
    } else {
      final trimmed = text.trim();
      if (trimmed.isNotEmpty) buffer.writeln('${'  ' * depth}$trimmed');
    }
  }
  return buffer.toString().trimRight();
}

/// 从 `Set-Cookie` 原始头中还原某个 cookie 的过期标签。
///
/// [DebugCookie] 模型不落过期字段（jar 仅用于过期剔除），故展示层从原始头
/// 重新提取：`Expires` 原文优先，其次 `Max-Age`，缺省为会话。
String cookieExpiryLabel(String name, List<String> setCookieValues) {
  for (final raw in setCookieValues) {
    for (final part in DebugCookieJar.splitSetCookieHeader(raw)) {
      final segments = part.split(';');
      if (segments.isEmpty) continue;
      final pair = segments.first.trim();
      final eq = pair.indexOf('=');
      if (eq <= 0) continue;
      if (pair.substring(0, eq).trim() != name) continue;
      String? expires;
      String? maxAge;
      for (var i = 1; i < segments.length; i++) {
        final segment = segments[i].trim();
        final sep = segment.indexOf('=');
        final attr = (sep < 0 ? segment : segment.substring(0, sep))
            .trim()
            .toLowerCase();
        final value = sep < 0 ? '' : segment.substring(sep + 1).trim();
        if (attr == 'expires') expires = value;
        if (attr == 'max-age') maxAge = value;
      }
      if (expires != null && expires.isNotEmpty) return expires;
      if (maxAge != null) {
        final seconds = int.tryParse(maxAge);
        if (seconds == null) return '会话';
        if (seconds <= 0) return '已过期';
        return 'Max-Age $seconds s';
      }
      return '会话';
    }
  }
  return '会话';
}

/// 毫秒耗时的人类可读格式。
String formatDuration(int durationMs) {
  if (durationMs < 1000) return '$durationMs ms';
  return '${(durationMs / 1000).toStringAsFixed(2)} s';
}
