import 'dart:convert';
import 'dart:math';

/// 允许的脚本体积上限（单个脚本，含 @require 预载）。
const int kWebUserScriptMaxBytes = 1024 * 1024;

/// 一条用户脚本（Tampermonkey 的兼容子集）。
///
/// 支持：`@name/@namespace/@version/@description/@author/@icon`、
/// `@match/@include/@exclude`、`@run-at`、`@grant`、`@require`、`@updateURL`。
/// 不支持：`@resource`、GM 菜单命令的真实注册、自动更新。
class WebUserScript {
  WebUserScript({
    required this.id,
    required this.name,
    this.namespace = '',
    this.version = '0.0.1',
    this.description = '',
    this.author = '',
    this.icon = '',
    this.matches = const [],
    this.includes = const [],
    this.excludes = const [],
    this.requires = const [],
    this.grants = const [],
    this.runAt = 'document-idle',
    required this.code,
    this.prelude = '',
    this.sourceUrl = '',
    this.enabled = true,
    this.values = const {},
    required this.installedAt,
    required this.updatedAt,
  });

  final String id;
  final String name;
  final String namespace;
  final String version;
  final String description;
  final String author;
  final String icon;

  /// `@match` / `@include` / `@exclude`（原始写法）。
  final List<String> matches;
  final List<String> includes;
  final List<String> excludes;

  /// `@require` 的地址（已经抓取过的内容在 [prelude] 里）。
  final List<String> requires;
  final List<String> grants;

  /// `document-start` / `document-end` / `document-idle`。
  final String runAt;

  /// 脚本原文（含 `// ==UserScript==` 元数据块）。
  final String code;

  /// `@require` 抓下来的库代码，拼接在脚本正文之前。
  final String prelude;

  final String sourceUrl;
  final bool enabled;

  /// `GM_setValue` 的持久化数据（按脚本隔离）。
  final Map<String, Object?> values;

  final int installedAt;
  final int updatedAt;

  /// 去重键：同 namespace + name 视为同一个脚本（用于「更新」）。
  String get key => '${namespace.isEmpty ? 'local' : namespace}::$name';

  bool get hasMatchers => matches.isNotEmpty || includes.isNotEmpty;

  /// 匹配表达式（用于 Dart 侧判断「这个页面用了哪些脚本」）。
  ///
  /// 与注入到页面的 JS 使用同一个正则源，避免两边行为不一致。
  String? get matchSource => _alternation([
        for (final pattern in matches)
          if (_matchPatternToRegExp(pattern) case final source?) source,
        for (final pattern in includes)
          if (_includeToRegExp(pattern) case final source?) source,
      ]);

  String? get excludeSource {
    final parts = <String>[];
    for (final pattern in excludes) {
      final source = _includeToRegExp(pattern) ?? _matchPatternToRegExp(pattern);
      if (source != null) parts.add(source);
    }
    return _alternation(parts);
  }

  /// 当前 URL 是否命中这个脚本（不考虑启用状态）。
  bool matchesUrl(String url) {
    if (!hasMatchers) return false;
    final positive = matchSource;
    if (positive == null) return false;
    if (!RegExp(positive, caseSensitive: false).hasMatch(url)) return false;
    final negative = excludeSource;
    if (negative != null &&
        RegExp(negative, caseSensitive: false).hasMatch(url)) {
      return false;
    }
    return true;
  }

  /// Android 侧 `addDocumentStartJavaScript` 的 origins 白名单。
  ///
  /// 只是一个优化：命中判断最终仍由脚本开头的正则完成，所以拿不准时返回
  /// `*`，宁可多注入一次也不漏。
  Set<String> get originRules {
    if (includes.isNotEmpty) return const {'*'};
    final rules = <String>{};
    for (final pattern in matches) {
      final parsed =
          RegExp(r'^(\*|https?):\/\/([^/]+)').firstMatch(pattern);
      if (parsed == null) return const {'*'};
      final scheme = parsed.group(1)!;
      final host = parsed.group(2)!;
      final schemes = scheme == '*' ? const ['https', 'http'] : [scheme];
      for (final item in schemes) {
        rules.add('$item://$host');
      }
    }
    return rules.isEmpty ? const {'*'} : rules;
  }

  WebUserScript copyWith({
    String? id,
    String? name,
    String? namespace,
    String? version,
    String? description,
    String? author,
    String? icon,
    List<String>? matches,
    List<String>? includes,
    List<String>? excludes,
    List<String>? requires,
    List<String>? grants,
    String? runAt,
    String? code,
    String? prelude,
    String? sourceUrl,
    bool? enabled,
    Map<String, Object?>? values,
    int? updatedAt,
  }) {
    return WebUserScript(
      id: id ?? this.id,
      name: name ?? this.name,
      namespace: namespace ?? this.namespace,
      version: version ?? this.version,
      description: description ?? this.description,
      author: author ?? this.author,
      icon: icon ?? this.icon,
      matches: matches ?? this.matches,
      includes: includes ?? this.includes,
      excludes: excludes ?? this.excludes,
      requires: requires ?? this.requires,
      grants: grants ?? this.grants,
      runAt: runAt ?? this.runAt,
      code: code ?? this.code,
      prelude: prelude ?? this.prelude,
      sourceUrl: sourceUrl ?? this.sourceUrl,
      enabled: enabled ?? this.enabled,
      values: values ?? this.values,
      installedAt: installedAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'namespace': namespace,
        'version': version,
        'description': description,
        'author': author,
        'icon': icon,
        'matches': matches,
        'includes': includes,
        'excludes': excludes,
        'requires': requires,
        'grants': grants,
        'runAt': runAt,
        'code': code,
        'prelude': prelude,
        'sourceUrl': sourceUrl,
        'enabled': enabled,
        'values': values,
        'installedAt': installedAt,
        'updatedAt': updatedAt,
      };

  factory WebUserScript.fromJson(Map<String, Object?> json) {
    List<String> strings(Object? value) => [
          if (value is List)
            for (final item in value)
              if (item != null) item.toString(),
        ];
    return WebUserScript(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      namespace: json['namespace']?.toString() ?? '',
      version: json['version']?.toString() ?? '0.0.1',
      description: json['description']?.toString() ?? '',
      author: json['author']?.toString() ?? '',
      icon: json['icon']?.toString() ?? '',
      matches: strings(json['matches']),
      includes: strings(json['includes']),
      excludes: strings(json['excludes']),
      requires: strings(json['requires']),
      grants: strings(json['grants']),
      runAt: json['runAt']?.toString() ?? 'document-idle',
      code: json['code']?.toString() ?? '',
      prelude: json['prelude']?.toString() ?? '',
      sourceUrl: json['sourceUrl']?.toString() ?? '',
      enabled: json['enabled'] as bool? ?? true,
      values: json['values'] is Map
          ? {
              for (final entry in (json['values'] as Map).entries)
                entry.key.toString(): entry.value,
            }
          : const {},
      installedAt: (json['installedAt'] as num?)?.toInt() ??
          DateTime.now().millisecondsSinceEpoch,
      updatedAt: (json['updatedAt'] as num?)?.toInt() ??
          DateTime.now().millisecondsSinceEpoch,
    );
  }
}

/// 元数据解析结果；[script] 为 null 表示没有合法的 UserScript 头。
class WebUserScriptParseResult {
  const WebUserScriptParseResult({this.script, this.error});

  final WebUserScript? script;
  final String? error;

  bool get ok => script != null;
}

/// `// ==UserScript== ... // ==/UserScript==` 元数据。
final RegExp _metadataBlock = RegExp(
  r'//\s*==UserScript==([\s\S]*?)//\s*==/UserScript==',
);

/// 解析脚本文本。`[id]` 为空时按 key 生成稳定 id。
WebUserScriptParseResult parseWebUserScript(
  String text, {
  String sourceUrl = '',
  String prelude = '',
  String? id,
  bool enabled = true,
}) {
  final source = text.trim();
  if (source.isEmpty) {
    return const WebUserScriptParseResult(error: '脚本内容为空');
  }
  if (source.length > kWebUserScriptMaxBytes) {
    return const WebUserScriptParseResult(error: '脚本太大（超过 1MB）');
  }
  final block = _metadataBlock.firstMatch(source);
  if (block == null) {
    return const WebUserScriptParseResult(
      error: '不是用户脚本：缺少 // ==UserScript== 元数据块',
    );
  }

  final name = <String>[];
  final namespace = <String>[];
  final version = <String>[];
  final description = <String>[];
  final author = <String>[];
  final icon = <String>[];
  final matches = <String>[];
  final includes = <String>[];
  final excludes = <String>[];
  final requires = <String>[];
  final grants = <String>[];
  final runAt = <String>[];
  final updateUrl = <String>[];

  final line = RegExp(r'^\s*//\s*@([A-Za-z0-9_:-]+)\s*(.*)$');
  for (final raw in block.group(1)!.split('\n')) {
    final parsed = line.firstMatch(raw);
    if (parsed == null) continue;
    final key = parsed.group(1)!.toLowerCase();
    final value = parsed.group(2)!.trim();
    switch (key) {
      case 'name':
        name.add(value);
      case 'namespace':
        namespace.add(value);
      case 'version':
        version.add(value);
      case 'description':
        description.add(value);
      case 'author':
        author.add(value);
      case 'icon':
      case 'iconurl':
        icon.add(value);
      case 'match':
        matches.add(value);
      case 'include':
        includes.add(value);
      case 'exclude':
        excludes.add(value);
      case 'require':
        requires.add(value);
      case 'grant':
        grants.add(value);
      case 'run-at':
        runAt.add(value);
      case 'updateurl':
      case 'downloadurl':
        updateUrl.add(value);
    }
  }

  final scriptName = name.isNotEmpty && name.first.isNotEmpty
      ? name.first
      : _fallbackName(sourceUrl);
  final scriptNamespace = namespace.isEmpty ? '' : namespace.first;
  final scriptId = id ??
      _stableId('$scriptNamespace::$scriptName::$sourceUrl');

  return WebUserScriptParseResult(
    script: WebUserScript(
      id: scriptId,
      name: scriptName,
      namespace: scriptNamespace,
      version: version.isEmpty ? '0.0.1' : version.first,
      description: description.isEmpty ? '' : description.first,
      author: author.isEmpty ? '' : author.first,
      icon: icon.isEmpty ? '' : icon.first,
      matches: matches,
      includes: includes,
      excludes: excludes,
      requires: requires,
      grants: grants,
      runAt: _normalizeRunAt(runAt.isEmpty ? '' : runAt.first),
      code: source,
      prelude: prelude,
      sourceUrl: updateUrl.isNotEmpty ? updateUrl.first : sourceUrl,
      enabled: enabled,
      installedAt: DateTime.now().millisecondsSinceEpoch,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    ),
  );
}

/// 从安装地址兜底一个脚本名。
String _fallbackName(String sourceUrl) {
  final segments = Uri.tryParse(sourceUrl)?.pathSegments ?? const <String>[];
  for (var index = segments.length - 1; index >= 0; index--) {
    if (segments[index].isNotEmpty) return segments[index];
  }
  return '未命名脚本';
}

String _normalizeRunAt(String raw) {
  switch (raw) {
    case 'document-start':
      return 'document-start';
    case 'document-end':
      return 'document-end';
    case 'document-idle':
      return 'document-idle';
    default:
      return 'document-idle';
  }
}

/// 稳定 id：对 key 做 FNV-1a，避免引入额外依赖。
String _stableId(String seed) {
  var hash = 0x811c9dc5;
  for (final unit in seed.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}

/// 每个 WebView 文档一个随机 token，只出现在注入脚本的闭包里。
String newUserScriptToken() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  return base64Url.encode(bytes).replaceAll('=', '');
}

/// 形如 `https://greasyfork.org/scripts/1/x.user.js` 的安装地址。
bool looksLikeUserScriptUrl(String url) {
  final uri = Uri.tryParse(url.trim());
  if (uri == null) return false;
  if (uri.scheme != 'http' && uri.scheme != 'https') return false;
  return uri.path.toLowerCase().endsWith('.user.js');
}

String? _alternation(List<String> parts) {
  if (parts.isEmpty) return null;
  if (parts.length == 1) return parts.first;
  return '(?:${parts.join('|')})';
}

/// `@match` 语法 → 正则（Chrome 扩展 match pattern 的子集）。
String? _matchPatternToRegExp(String pattern) {
  final match =
      RegExp(r'^(\*|https?|ftp|file):\/\/([^/]*)(\/.*)?$').firstMatch(pattern);
  if (match == null) return null;
  final scheme = match.group(1)!;
  final host = match.group(2)!;
  final path = match.group(3) ?? '/*';
  if (host.isEmpty) return null;

  final schemeSource = scheme == '*' ? 'https?' : _escape(scheme);
  final hostSource = host == '*'
      ? '[^/]+'
      : host.startsWith('*.')
          ? '(?:[^/]+\\.)?${_escape(host.substring(2))}'
          : _escape(host);
  final pathSource = _globToRegExp(path);
  return '^$schemeSource://$hostSource$pathSource\$';
}

/// `@include` / `@exclude`：`/regex/` 或 glob。
String? _includeToRegExp(String pattern) {
  final text = pattern.trim();
  if (text.isEmpty) return null;
  if (text.length > 2 && text.startsWith('/') && text.endsWith('/')) {
    return text.substring(1, text.length - 1);
  }
  return '^${_globToRegExp(text)}\$';
}

/// 把 `*` 通配符串转成正则片段（其余字符全部转义）。
String _globToRegExp(String glob) {
  final buffer = StringBuffer();
  for (final rune in glob.runes) {
    final char = String.fromCharCode(rune);
    if (char == '*') {
      buffer.write('.*');
    } else {
      buffer.write(_escape(char));
    }
  }
  return buffer.toString();
}

String _escape(String text) =>
    text.replaceAllMapped(RegExp(r'[.*+?^${}()|[\]\\]'), (m) => '\\${m[0]}');

/// 生成注入到页面的引导脚本。
///
/// 设计要点：
/// * GM_* 全部是函数作用域内的局部变量，不挂到 `window`，页面 JS 拿不到，
///   也就无法借 `GM_xmlhttpRequest` 带着 token 发请求；
/// * `token` 只出现在闭包里，用于校验来自本脚本的桥调用；
/// * 匹配在脚本开头再做一次（origin 白名单只是优化）。
String buildUserScriptBootstrap(WebUserScript script, {required String token}) {
  final positive = script.matchSource;
  if (positive == null) return '';
  final negative = script.excludeSource;
  final name = jsonEncode(script.name);
  final namespace = jsonEncode(script.namespace);
  final version = jsonEncode(script.version);
  final description = jsonEncode(script.description);
  final id = jsonEncode(script.id);
  final values = jsonEncode(script.values);
  final matches = jsonEncode(script.matches);
  final tokenLiteral = jsonEncode(token);
  final body = '${script.prelude}\n${script.code}';

  final schedule = switch (script.runAt) {
    'document-start' => 'run();',
    'document-end' => '''
if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', run, { once: true });
} else { run(); }''',
    _ => '''
if (document.readyState === 'complete') { setTimeout(run, 0); }
else { window.addEventListener('load', function () { setTimeout(run, 0); }, { once: true }); }''',
  };

  return '''
(function () {
  var __gsId = $id;
  var __gsToken = $tokenLiteral;
  var __gsName = $name;
  var __gsValues = $values;
  var __gsMatch = new RegExp(${jsonEncode(positive)}, 'i');
  var __gsExclude = ${negative == null ? 'null' : 'new RegExp(${jsonEncode(negative)}, \'i\')'};
  if (!__gsMatch.test(location.href)) return;
  if (__gsExclude && __gsExclude.test(location.href)) return;
  var __gsLoaded = window.__gstoreUserScripts || (window.__gstoreUserScripts = {});
  if (__gsLoaded[__gsId]) return;
  __gsLoaded[__gsId] = true;

  function __gsCall(payload) {
    payload.token = __gsToken;
    try {
      return window.flutter_inappwebview.callHandler('gstoreUserscript', payload);
    } catch (error) {
      return Promise.reject(error);
    }
  }

  var GM_info = {
    scriptHandler: 'GStore 用户脚本',
    version: '1.0',
    script: {
      name: $name,
      namespace: $namespace,
      version: $version,
      description: $description,
      matches: $matches
    }
  };
  function GM_addStyle(css) {
    var style = document.createElement('style');
    style.textContent = String(css);
    (document.head || document.documentElement).appendChild(style);
    return style;
  }
  function GM_getValue(key, fallback) {
    return Object.prototype.hasOwnProperty.call(__gsValues, key)
      ? __gsValues[key]
      : fallback;
  }
  function GM_setValue(key, value) {
    __gsValues[key] = value;
    return __gsCall({ op: 'value.set', key: String(key), value: value });
  }
  function GM_deleteValue(key) {
    delete __gsValues[key];
    return __gsCall({ op: 'value.delete', key: String(key) });
  }
  function GM_listValues() {
    return Object.keys(__gsValues);
  }
  function GM_log() {
    var args = Array.prototype.slice.call(arguments).map(function (item) {
      try { return String(item); } catch (error) { return ''; }
    });
    return __gsCall({ op: 'log', args: args });
  }
  function GM_notification(details) {
    details = details || {};
    return __gsCall({
      op: 'notify',
      title: details.title || __gsName,
      text: details.text || ''
    });
  }
  function GM_openInTab(url) {
    return __gsCall({ op: 'open', url: String(url) });
  }
  function GM_setClipboard(text) {
    return __gsCall({ op: 'clipboard', text: String(text) });
  }
  function GM_registerMenuCommand() {
    return 0;
  }
  function GM_xmlhttpRequest(details) {
    var d = details || {};
    return __gsCall({
      op: 'xhr',
      method: d.method || 'GET',
      url: String(d.url || ''),
      headers: d.headers || {},
      data: d.data == null ? null : String(d.data),
      timeout: d.timeout || 30000
    }).then(function (response) {
      if (typeof d.onload === 'function') d.onload(response);
      return response;
    }, function (error) {
      if (typeof d.onerror === 'function') d.onerror(error);
      throw error;
    });
  }
  var GM = {
    info: GM_info,
    addStyle: GM_addStyle,
    getValue: GM_getValue,
    setValue: GM_setValue,
    deleteValue: GM_deleteValue,
    listValues: GM_listValues,
    log: GM_log,
    notification: GM_notification,
    openInTab: GM_openInTab,
    setClipboard: GM_setClipboard,
    registerMenuCommand: GM_registerMenuCommand,
    xmlHttpRequest: GM_xmlhttpRequest
  };

  function run() {
    try {
      (function () {
        var unsafeWindow = window;
        $body
      }).call(window);
    } catch (error) {
      try {
        console.error('[GStore userscript] ' + __gsName + ': ' + error);
      } catch (ignored) {}
    }
  }
  $schedule
})();
''';
}
