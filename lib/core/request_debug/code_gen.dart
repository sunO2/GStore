/// 「请求调试」多语言代码生成（plan todo 19，纯函数，无 IO / 无 UI / 无依赖）。
///
/// 把 [DebugRequest] 渲染为可直接复制到目标语言 / 工具的请求片段：
/// cURL / Dart(Dio) / Python(requests) / JavaScript(fetch) / Go(net/http) / HTTPie。
///
/// 关键不变量：
/// - **`{{var}}` 占位符逐字保留**：绝不 `Uri.parse` / 绝不百分号编码花括号，
///   URL 合成复用 [effectiveUrl]（手动扫描，见 `query_codec.dart`），因此
///   `https://{{host}}/path?q={{q}}` 在全部语言中保持原样，交由目标运行时 /
///   环境解析在发送前替换。
/// - **纯函数**：不修改入参、无副作用；同输入恒等输出。
/// - **零依赖**：仅复用本目录既有纯逻辑（[applyAuth] / [effectiveUrl] /
///   [toCurl]），不引入任何第三方包，也**不改变** cURL 导出（cURL 语言直接
///   复用 [toCurl] 的既有输出）。
/// - **空请求安全**：方法 / URL / 头 / 体缺省时仍生成语法上合法的非空片段，
///   绝不抛异常。
library;

import 'debug_models.dart';
import 'auth_apply.dart';
import 'curl_codec.dart';

/// 支持生成的目标语言 / 工具。
enum CodeGenLanguage {
  curl('cURL'),
  dartDio('Dart (Dio)'),
  pythonRequests('Python (requests)'),
  javascriptFetch('JavaScript (fetch)'),
  goNetHttp('Go (net/http)'),
  httpie('HTTPie');

  const CodeGenLanguage(this.label);

  /// 展示名（UI 下拉 / 菜单用）。
  final String label;
}

/// 生成 [request] 在 [language] 下的请求片段。
///
/// 纯函数：不修改 [request]；`{{var}}` 占位符逐字保留。
String generateCode(DebugRequest request, CodeGenLanguage language) {
  switch (language) {
    case CodeGenLanguage.curl:
      return toCurl(request);
    case CodeGenLanguage.dartDio:
      return _dartDio(request);
    case CodeGenLanguage.pythonRequests:
      return _pythonRequests(request);
    case CodeGenLanguage.javascriptFetch:
      return _javascriptFetch(request);
    case CodeGenLanguage.goNetHttp:
      return _goNetHttp(request);
    case CodeGenLanguage.httpie:
      return _httpie(request);
  }
}

/// 一次性生成全部语言的片段（键为 [CodeGenLanguage]）。
Map<CodeGenLanguage, String> generateAllCode(DebugRequest request) {
  return <CodeGenLanguage, String>{
    for (final language in CodeGenLanguage.values)
      language: generateCode(request, language),
  };
}

// ==================== 公共投影 ====================

/// 生效 URL：应用认证（APIKey-query 并入查询）后按既有合并规则合成，
/// `{{var}}` 原样保留。复用 [effectiveUrl]（手动扫描，不 `Uri.parse`）。
String _effectiveUrl(DebugRequest request) {
  final applied = applyAuth(
    auth: request.auth,
    headers: request.headers,
    query: request.query,
  );
  return effectiveUrl(request.copyWith(query: applied.query));
}

/// 生效头集合：应用认证后的启用头 + 由 cookies 合成的单个 `Cookie` 头。
///
/// 顺序与 cURL 导出一致（头在前，Cookie 在后），且不重复输出同名 `Cookie`。
List<DebugHeader> _effectiveHeaders(DebugRequest request) {
  final applied = applyAuth(
    auth: request.auth,
    headers: request.headers,
    query: request.query,
  );
  final out = <DebugHeader>[
    for (final header in applied.headers)
      if (header.enabled && header.name.isNotEmpty) header,
  ];
  final cookieParts = request.cookies
      .where((c) => c.name.isNotEmpty)
      .map((c) => '${c.name}=${c.value}')
      .toList();
  if (cookieParts.isNotEmpty &&
      !out.any((h) => h.name.toLowerCase() == 'cookie')) {
    out.add(DebugHeader(name: 'Cookie', value: cookieParts.join('; ')));
  }
  return out;
}

// ==================== Dart (Dio) ====================

String _dartDio(DebugRequest request) {
  final url = _effectiveUrl(request);
  final headers = _effectiveHeaders(request);
  final b = StringBuffer()
    ..writeln('final response = await Dio().request(')
    ..writeln('  ${_dartStr(url)},')
    ..writeln('  options: Options(')
    ..writeln('    method: ${_dartStr(request.method)},');
  if (headers.isNotEmpty) {
    b.writeln('    headers: {');
    for (final header in headers) {
      b.writeln('      ${_dartStr(header.name)}: ${_dartStr(header.value)},');
    }
    b.writeln('    },');
  }
  b.writeln('  ),');
  if (request.body.isNotEmpty) {
    b.writeln('  data: ${_dartStr(request.body)},');
  }
  b.writeln(');');
  return b.toString();
}

// ==================== Python (requests) ====================

String _pythonRequests(DebugRequest request) {
  final url = _effectiveUrl(request);
  final headers = _effectiveHeaders(request);
  final b = StringBuffer()
    ..writeln('import requests')
    ..writeln()
    ..writeln('url = ${_pyStr(url)}');
  if (headers.isNotEmpty) {
    b.writeln('headers = {');
    for (final header in headers) {
      b.writeln('    ${_pyStr(header.name)}: ${_pyStr(header.value)},');
    }
    b.writeln('}');
  }
  if (request.body.isNotEmpty) {
    b.writeln('data = ${_pyStr(request.body)}');
  }
  final args = <String>[_pyStr(request.method), 'url'];
  if (headers.isNotEmpty) args.add('headers=headers');
  if (request.body.isNotEmpty) args.add('data=data');
  b
    ..writeln('response = requests.request(${args.join(', ')})')
    ..writeln('print(response.status_code)')
    ..writeln('print(response.text)');
  return b.toString();
}

// ==================== JavaScript (fetch) ====================

String _javascriptFetch(DebugRequest request) {
  final url = _effectiveUrl(request);
  final headers = _effectiveHeaders(request);
  final b = StringBuffer()
    ..writeln('const response = await fetch(${_jsStr(url)}, {')
    ..writeln('  method: ${_jsStr(request.method)},');
  if (headers.isNotEmpty) {
    b.writeln('  headers: {');
    for (final header in headers) {
      b.writeln('    ${_jsStr(header.name)}: ${_jsStr(header.value)},');
    }
    b.writeln('  },');
  }
  if (request.body.isNotEmpty) {
    b.writeln('  body: ${_jsStr(request.body)},');
  }
  b
    ..writeln('});')
    ..writeln('const text = await response.text();')
    ..writeln('console.log(response.status, text);');
  return b.toString();
}

// ==================== Go (net/http) ====================

String _goNetHttp(DebugRequest request) {
  final url = _effectiveUrl(request);
  final headers = _effectiveHeaders(request);
  final hasBody = request.body.isNotEmpty;
  final b = StringBuffer()
    ..writeln('package main')
    ..writeln()
    ..writeln('import (')
    ..writeln('\t"io"')
    ..writeln('\t"net/http"');
  if (hasBody) b.writeln('\t"strings"');
  b
    ..writeln(')')
    ..writeln()
    ..writeln('func main() {');
  if (hasBody) {
    b.writeln('\tbody := strings.NewReader(${_goRawOrQuoted(request.body)})');
    b.writeln('\treq, err := http.NewRequest('
        '${_goStr(request.method)}, ${_goStr(url)}, body)');
  } else {
    b.writeln('\treq, err := http.NewRequest('
        '${_goStr(request.method)}, ${_goStr(url)}, nil)');
  }
  b
    ..writeln('\tif err != nil {')
    ..writeln('\t\tpanic(err)')
    ..writeln('\t}');
  for (final header in headers) {
    b.writeln('\treq.Header.Set(${_goStr(header.name)}, ${_goStr(header.value)})');
  }
  b
    ..writeln('\tresp, err := http.DefaultClient.Do(req)')
    ..writeln('\tif err != nil {')
    ..writeln('\t\tpanic(err)')
    ..writeln('\t}')
    ..writeln('\tdefer resp.Body.Close()')
    ..writeln('\tres, _ := io.ReadAll(resp.Body)')
    ..writeln('\tprintln(string(res))')
    ..writeln('}');
  return b.toString();
}

// ==================== HTTPie ====================

String _httpie(DebugRequest request) {
  final url = _effectiveUrl(request);
  final headers = _effectiveHeaders(request);
  final b = StringBuffer('http ${request.method} ${_shellStr(url)}');
  for (final header in headers) {
    b.write(' \\\n  ${_shellStr('${header.name}:${header.value}')}');
  }
  if (request.body.isNotEmpty) {
    b.write(' \\\n  --raw ${_shellStr(request.body)}');
  }
  return b.toString();
}

// ==================== 转义辅助（保持 {{var}} 原样）====================

/// Dart 单引号字符串字面量转义（`\` / `'` / `$` / 控制字符）。
String _dartStr(String s) => _quoted(s, quote: "'", escapeDollar: true);

/// Python 单引号字符串字面量转义。
String _pyStr(String s) => _quoted(s, quote: "'");

/// JavaScript 单引号字符串字面量转义。
String _jsStr(String s) => _quoted(s, quote: "'");

/// Go 双引号字符串字面量转义。
String _goStr(String s) {
  final b = StringBuffer('"');
  for (final rune in s.runes) {
    final c = String.fromCharCode(rune);
    switch (c) {
      case r'\\':
        b.write(r'\\');
      case '"':
        b.write(r'\"');
      case '\n':
        b.write(r'\n');
      case '\r':
        b.write(r'\r');
      case '\t':
        b.write(r'\t');
      default:
        b.write(c);
    }
  }
  b.write('"');
  return b.toString();
}

/// Go 原始字符串（反引号）：仅在内容不含反引号 / `\r` 时使用，可让含双引号的
/// JSON 体保持逐字可读；否则退回 [_goStr]。
String _goRawOrQuoted(String s) {
  if (!s.contains('`') && !s.contains('\r')) return '`$s`';
  return _goStr(s);
}

/// POSIX shell 单引号转义（HTTPie）。
String _shellStr(String s) => "'${s.replaceAll("'", "'\\''")}'";

/// 单引号字符串转义：`\`、换行、制表、引号本身；可选转义 `$`（Dart 插值）。
String _quoted(String s, {required String quote, bool escapeDollar = false}) {
  final b = StringBuffer(quote);
  for (final rune in s.runes) {
    final c = String.fromCharCode(rune);
    if (c == '\\') {
      b.write(r'\\');
    } else if (c == quote) {
      b.write('\\$quote');
    } else if (c == '\n') {
      b.write(r'\n');
    } else if (c == '\r') {
      b.write(r'\r');
    } else if (c == '\t') {
      b.write(r'\t');
    } else if (escapeDollar && c == r'$') {
      b.write(r'\$');
    } else {
      b.write(c);
    }
  }
  b.write(quote);
  return b.toString();
}
