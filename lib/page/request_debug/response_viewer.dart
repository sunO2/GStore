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

  @override
  State<ResponseViewer> createState() => _ResponseViewerState();
}

class _ResponseViewerState extends State<ResponseViewer> {
  ResponseViewerTab _tab = ResponseViewerTab.body;
  ResponseBodyFormat _format = ResponseBodyFormat.formatted;

  /// 当前已展开的字符数（分块续载）。
  int _visibleChars = ResponseViewer.chunkChars;
  bool _saving = false;

  DebugResponse get _response => widget.response;

  @override
  void didUpdateWidget(ResponseViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 换了一次响应（重发）：回到 Body 默认态并重置分块。
    if (!identical(oldWidget.response, widget.response)) {
      _tab = ResponseViewerTab.body;
      _format = ResponseBodyFormat.formatted;
      _visibleChars = ResponseViewer.chunkChars;
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
  String get _displayText {
    if (_bodyKind == ResponseBodyKind.binary) return '';
    final raw = _response.bodyText;
    if (_format == ResponseBodyFormat.raw) return raw;
    switch (_bodyKind) {
      case ResponseBodyKind.json:
        return tryPrettyJson(raw) ?? raw;
      case ResponseBodyKind.xml:
        return prettyXml(raw);
      case ResponseBodyKind.html:
      case ResponseBodyKind.text:
      case ResponseBodyKind.binary:
        return raw;
    }
  }

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
              _visibleChars = ResponseViewer.chunkChars;
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
              _visibleChars = ResponseViewer.chunkChars;
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
      return _buildEmpty(context, '无响应头');
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
    final kind = _bodyKind;
    if (kind == ResponseBodyKind.binary) {
      return _buildBinary(context);
    }
    final text = _displayText;
    if (text.isEmpty) {
      return _buildEmpty(context, '响应体为空');
    }
    final note = kind == ResponseBodyKind.json &&
            _format == ResponseBodyFormat.formatted &&
            tryPrettyJson(_response.bodyText) == null
        ? 'JSON 解析失败，已按原文展示'
        : null;
    return _buildChunkedText(
      context,
      text,
      keyPrefix: 'response-body',
      note: note,
    );
  }

  Widget _buildRaw(BuildContext context) {
    final text = _response.bodyText;
    if (text.isEmpty) {
      return _buildEmpty(context, '响应体为空');
    }
    return _buildChunkedText(
      context,
      text,
      keyPrefix: 'response-raw',
      note: null,
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
        SelectableText(
          shown,
          key: Key('$keyPrefix-text'),
          style: AppTypography.code,
        ),
      ],
    );
  }

  Widget _buildBinary(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return ListView(
      padding: AppSpacing.allLG,
      children: [
        Container(
          key: const Key('response-body-binary'),
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
                      '${byteSize(_response.sizeBytes)} · 不显示为文本（可点击复制原始预览）',
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

  Widget _buildCookies(BuildContext context) {
    final theme = Theme.of(context);
    final rows = _cookieRows;
    if (rows.isEmpty) {
      return _buildEmpty(context, '无 Cookie');
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

  Widget _buildEmpty(BuildContext context, String message) {
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
