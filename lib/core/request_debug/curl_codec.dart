/// 手写 cURL 导入 / 导出编解码（plan todo 27）。
///
/// 设计要点：
/// - **不执行** curl、不 spawn 进程、不读文件（`-b cookies.txt` / `@file`
///   等文件引用明确记录为「忽略」，绝不静默错误解析）。
/// - 不引入任何新依赖：仅用 `dart:convert` 做 JSON 推断与 Basic 认证编码。
/// - [parseCurl] **绝不抛出**：非法输入或未知选项统一通过
///   [CurlParseResult] 的 [CurlParseResult.error] / [CurlParseResult.ignoredOptions]
///   结构化返回，调用方可安全展示。
/// - 支持 `-X` / `-H` / `--header` / `-d` / `--data` / `--data-raw` /
///   `--data-binary` / `-b` / `--cookie` / `--url` / 位置 URL / `-F` / `--form`
///   （multipart 可选）/ `-A` / `-u` / `-e`，并推断方法（有 body 即 POST）。
library;

import 'dart:convert';

import 'debug_models.dart';

/// cURL 解析结果：成功携带 [request]，失败携带 [error]。
///
/// [ignoredOptions] 同时适用于成功与失败，用于明确告知哪些选项被忽略。
class CurlParseResult {
  const CurlParseResult._(this.request, this.error, this.ignoredOptions);

  /// 解析出的请求（失败时为 `null`）。
  final DebugRequest? request;

  /// 人类可读的错误信息（成功时为 `null`）。
  final String? error;

  /// 被明确忽略的选项 / 片段（如 `--compressed`、`-b cookies.txt`）。
  final List<String> ignoredOptions;

  /// 是否解析成功。
  bool get isSuccess => request != null;

  factory CurlParseResult.success(
    DebugRequest request, {
    List<String> ignored = const [],
  }) =>
      CurlParseResult._(request, null, List.unmodifiable(ignored));

  factory CurlParseResult.failure(
    String error, {
    List<String> ignored = const [],
  }) =>
      CurlParseResult._(null, error, List.unmodifiable(ignored));
}

/// 解析一条 cURL 命令为 [DebugRequest]。
///
/// 永不抛异常；任何非法输入返回 [CurlParseResult.failure]。
CurlParseResult parseCurl(String curl) {
  try {
    return _parse(curl);
  } catch (e) {
    return CurlParseResult.failure('解析失败：$e');
  }
}

CurlParseResult _parse(String curl) {
  final ignored = <String>[];
  if (curl.trim().isEmpty) {
    return CurlParseResult.failure('cURL 命令为空');
  }

  final tokens = _tokenize(curl);
  if (tokens.isEmpty) {
    return CurlParseResult.failure('cURL 命令为空');
  }

  final first = tokens.first;
  final base = first.split('/').last.split('\\').last.toLowerCase();
  if (base != 'curl' && base != 'curl.exe') {
    return CurlParseResult.failure('不是 curl 命令：$first');
  }

  String? explicitMethod;
  String? url;
  final headers = <DebugHeader>[];
  final cookies = <DebugCookie>[];
  final bodyParts = <String>[];
  final formParts = <String>[];

  var headFlag = false;
  var getFlag = false;
  var hadData = false;
  var binaryFlag = false;

  void addHeader(String raw) {
    final idx = raw.indexOf(':');
    if (idx <= 0) {
      ignored.add('无效 header（忽略）：$raw');
      return;
    }
    final name = raw.substring(0, idx).trim();
    final value = raw.substring(idx + 1).trim();
    if (name.isEmpty) {
      ignored.add('无效 header（忽略）：$raw');
      return;
    }
    headers.add(DebugHeader(name: name, value: value));
  }

  void addCookies(String raw) {
    var any = false;
    for (final part in raw.split(';')) {
      final s = part.trim();
      if (s.isEmpty) continue;
      final eq = s.indexOf('=');
      if (eq <= 0) continue;
      cookies.add(DebugCookie(
        name: s.substring(0, eq).trim(),
        value: s.substring(eq + 1),
      ));
      any = true;
    }
    if (!any) {
      ignored.add('cookie 文件引用未读取（忽略）：$raw');
    }
  }

  var i = 1;
  while (i < tokens.length) {
    final token = tokens[i];
    String name;
    String? attached;

    if (token.startsWith('--')) {
      final eq = token.indexOf('=');
      if (eq >= 0) {
        name = token.substring(0, eq);
        attached = token.substring(eq + 1);
      } else {
        name = token;
      }
    } else if (token.startsWith('-') && token.length > 1) {
      name = token.substring(0, 2);
      if (token.length > 2) attached = token.substring(2);
    } else {
      // 位置参数 URL（首个胜出，其余记录忽略）。
      if (url == null) {
        url = token;
      } else {
        ignored.add('多余位置参数（忽略）：$token');
      }
      i++;
      continue;
    }

    // 取值的辅助：优先使用 `--flag=value` / `-Xvalue` 的贴附值。
    String? takeValue() {
      if (attached != null) return attached;
      if (i + 1 < tokens.length) {
        i++;
        return tokens[i];
      }
      return null;
    }

    switch (name) {
      case '-X':
      case '--request':
        final v = takeValue();
        if (v == null || v.isEmpty) {
          ignored.add('$name 缺少值（忽略）');
        } else {
          explicitMethod = v;
        }
        break;
      case '-H':
      case '--header':
        final v = takeValue();
        if (v == null) {
          ignored.add('header 缺少值（忽略）：$name');
        } else {
          addHeader(v);
        }
        break;
      case '-d':
      case '--data':
      case '--data-raw':
      case '--data-ascii':
        final v = takeValue();
        if (v == null) {
          ignored.add('$name 缺少值（忽略）');
        } else {
          if (v.startsWith('@')) {
            ignored.add('$name 文件引用未读取（忽略）：$v');
          } else {
            bodyParts.add(v);
            hadData = true;
          }
        }
        break;
      case '--data-binary':
        final v = takeValue();
        if (v == null) {
          ignored.add('$name 缺少值（忽略）');
        } else if (v.startsWith('@')) {
          ignored.add('$name 文件引用未读取（忽略）：$v');
        } else {
          bodyParts.add(v);
          hadData = true;
          binaryFlag = true;
        }
        break;
      case '-b':
      case '--cookie':
        final v = takeValue();
        if (v == null) {
          ignored.add('$name 缺少值（忽略）');
        } else if (v.contains('=')) {
          addCookies(v);
        } else {
          ignored.add('cookie 文件引用未读取（忽略）：$v');
        }
        break;
      case '--url':
        final v = takeValue();
        if (v == null || v.isEmpty) {
          ignored.add('$name 缺少值（忽略）');
        } else {
          url = v;
        }
        break;
      case '-F':
      case '--form':
      case '--form-string':
        final v = takeValue();
        if (v == null) {
          ignored.add('$name 缺少值（忽略）');
        } else {
          formParts.add(v);
        }
        break;
      case '-A':
      case '--user-agent':
        final v = takeValue();
        if (v == null) {
          ignored.add('$name 缺少值（忽略）');
        } else {
          headers.add(DebugHeader(name: 'User-Agent', value: v));
        }
        break;
      case '-e':
      case '--referer':
        final v = takeValue();
        if (v == null) {
          ignored.add('$name 缺少值（忽略）');
        } else {
          headers.add(DebugHeader(name: 'Referer', value: v));
        }
        break;
      case '-u':
      case '--user':
        final v = takeValue();
        if (v == null) {
          ignored.add('$name 缺少值（忽略）');
        } else {
          final encoded = base64Encode(utf8.encode(v));
          headers.add(DebugHeader(
            name: 'Authorization',
            value: 'Basic $encoded',
          ));
        }
        break;
      case '-I':
      case '--head':
        headFlag = true;
        break;
      case '-G':
      case '--get':
        getFlag = true;
        break;
      default:
        // 明确忽略：已知/未知的取值型长选项消费其值，避免错位。
        if (attached == null && _valueTakingFlags.contains(name)) {
          final v = takeValue();
          ignored.add('$name${v == null ? '' : ' $v'}（忽略）');
        } else {
          ignored.add('$name（忽略）');
        }
        break;
    }
    i++;
  }

  // -G：体数据转查询串附加到 URL。
  if (getFlag && bodyParts.isNotEmpty) {
    final qs = bodyParts.join('&');
    final baseUrl = url ?? '';
    url = baseUrl.isEmpty
        ? '?$qs'
        : (baseUrl.contains('?') ? '$baseUrl&$qs' : '$baseUrl?$qs');
    bodyParts.clear();
    hadData = false;
  }

  final trimmedUrl = (url ?? '').trim();
  if (trimmedUrl.isEmpty) {
    return CurlParseResult.failure('cURL 缺少 URL', ignored: ignored);
  }

  final String method;
  if (explicitMethod != null && explicitMethod.isNotEmpty) {
    method = explicitMethod.toUpperCase();
  } else if (headFlag) {
    method = 'HEAD';
  } else if (getFlag) {
    method = 'GET';
  } else if (bodyParts.isNotEmpty || formParts.isNotEmpty) {
    method = 'POST';
  } else {
    method = 'GET';
  }

  final DebugBodyKind bodyKind;
  final String body;
  if (formParts.isNotEmpty) {
    bodyKind = DebugBodyKind.multipart;
    body = formParts.join('\n');
  } else if (hadData) {
    body = bodyParts.join('&');
    var kind = _inferBodyKind(body, headers);
    if (binaryFlag && kind == DebugBodyKind.text) {
      kind = DebugBodyKind.binary;
    }
    bodyKind = kind;
  } else {
    bodyKind = DebugBodyKind.none;
    body = '';
  }

  final request = DebugRequest(
    id: generateDebugId('curl'),
    name: trimmedUrl,
    method: method,
    url: trimmedUrl,
    headers: headers,
    body: body,
    bodyKind: bodyKind,
    cookies: cookies,
  );

  return CurlParseResult.success(request, ignored: ignored);
}

/// 由 content-type 头或 body 内容推断 [DebugBodyKind]。
DebugBodyKind _inferBodyKind(String body, List<DebugHeader> headers) {
  final ct = headers
      .firstWhere(
        (h) => h.name.toLowerCase() == 'content-type',
        orElse: () => const DebugHeader(name: ''),
      )
      .value
      .toLowerCase();
  if (ct.contains('application/json') || ct.contains('+json')) {
    return DebugBodyKind.json;
  }
  if (ct.contains('application/x-www-form-urlencoded')) {
    return DebugBodyKind.formUrlEncoded;
  }
  final t = body.trim();
  if ((t.startsWith('{') && t.endsWith('}')) ||
      (t.startsWith('[') && t.endsWith(']'))) {
    try {
      jsonDecode(t);
      return DebugBodyKind.json;
    } catch (_) {
      // 非合法 JSON，继续后续启发式判断。
    }
  }
  // 形如 `a=1&b=2` 的键值对（每段都含 `=`）判定为表单编码。
  if (t.isNotEmpty && t.contains('=')) {
    final segments = t.split('&');
    if (segments.every((s) => s.contains('=') && !s.startsWith('='))) {
      return DebugBodyKind.formUrlEncoded;
    }
  }
  return DebugBodyKind.text;
}

/// 已知「取值型」长选项集合：用于在忽略它们时正确消费其值，避免后续错位。
const Set<String> _valueTakingFlags = {
  '--connect-timeout',
  '--max-time',
  '--output',
  '--proxy',
  '--cacert',
  '--cert',
  '--key',
  '--resolve',
  '--proto',
  '--retry',
  '--retry-delay',
  '--limit-rate',
  '--interface',
  '--write-out',
  '--dump-header',
  '--cookie-jar',
  '--oauth2-bearer',
  '--aws-sigv4',
  '--cert-type',
  '--key-type',
  '--pass',
  '--ciphers',
  '--tlsv1.2',
};

/// 把 [DebugRequest] 序列化为等价 cURL 命令（单引号转义）。
///
/// 输出可被 [parseCurl] 再次解析并保持等价。
String toCurl(DebugRequest req) {
  final b = StringBuffer('curl');
  b.write(' -X ${_shellQuote(req.method)}');

  final url = effectiveUrl(req);
  if (url.isNotEmpty) {
    b.write(' ${_shellQuote(url)}');
  }

  for (final h in req.headers) {
    if (!h.enabled || h.name.isEmpty) continue;
    b.write(' -H ${_shellQuote('${h.name}: ${h.value}')}');
  }

  final cookieParts = req.cookies
      .where((c) => c.name.isNotEmpty)
      .map((c) => '${c.name}=${c.value}')
      .toList();
  if (cookieParts.isNotEmpty) {
    b.write(' -b ${_shellQuote(cookieParts.join('; '))}');
  }

  if (req.bodyKind == DebugBodyKind.multipart && req.body.isNotEmpty) {
    for (final part in req.body.split('\n')) {
      if (part.isEmpty) continue;
      b.write(' -F ${_shellQuote(part)}');
    }
  } else if (req.bodyKind != DebugBodyKind.none || req.body.isNotEmpty) {
    final flag =
        req.bodyKind == DebugBodyKind.binary ? '--data-binary' : '-d';
    b.write(' $flag ${_shellQuote(req.body)}');
  }

  return b.toString();
}

/// 合并启用的查询参数到 URL（用于导出）。
String effectiveUrl(DebugRequest req) {
  final enabled = req.query.where((q) => q.enabled && q.name.isNotEmpty);
  if (enabled.isEmpty) return req.url;
  final qs = enabled
      .map((q) => q.value.isEmpty
          ? Uri.encodeQueryComponent(q.name)
          : '${Uri.encodeQueryComponent(q.name)}='
              '${Uri.encodeQueryComponent(q.value)}')
      .join('&');
  if (req.url.contains('?')) return '${req.url}&$qs';
  return '${req.url}?$qs';
}

/// POSIX 风格单引号转义：`'` → `'\''`。
String _shellQuote(String s) => "'${s.replaceAll("'", "'\\''")}'";

// ==================== 分词器 ====================

/// 将一个 shell 风格的 cURL 命令切分为参数 token。
///
/// 支持：单引号、双引号（含 `\" \\ \$ \`` 转义）、`$'...'` ANSI-C 引号、
/// 反斜杠转义与反斜杠换行续接。未闭合引号抛 [FormatException]。
List<String> _tokenize(String input) {
  final tokens = <String>[];
  final buf = StringBuffer();
  var inToken = false;
  var i = 0;

  while (i < input.length) {
    final c = input[i];

    if (c == '\\') {
      if (i + 1 < input.length) {
        final n = input[i + 1];
        if (n == '\n') {
          i += 2;
          continue;
        }
        if (n == '\r' && i + 2 < input.length && input[i + 2] == '\n') {
          i += 3;
          continue;
        }
        buf.write(n);
        inToken = true;
        i += 2;
        continue;
      }
      i++;
      continue;
    }

    if (c == "'") {
      inToken = true;
      final end = input.indexOf("'", i + 1);
      if (end < 0) throw const FormatException('未闭合的单引号');
      buf.write(input.substring(i + 1, end));
      i = end + 1;
      continue;
    }

    if (c == '"') {
      inToken = true;
      i++;
      var closed = false;
      while (i < input.length) {
        final d = input[i];
        if (d == '\\' && i + 1 < input.length) {
          final n = input[i + 1];
          if (n == '"' || n == '\\' || n == r'$' || n == '`') {
            buf.write(n);
            i += 2;
            continue;
          }
          if (n == '\n') {
            i += 2;
            continue;
          }
          buf.write(d);
          i++;
          continue;
        }
        if (d == '"') {
          closed = true;
          i++;
          break;
        }
        buf.write(d);
        i++;
      }
      if (!closed) throw const FormatException('未闭合的双引号');
      continue;
    }

    if (c == r'$' && i + 1 < input.length && input[i + 1] == "'") {
      inToken = true;
      i += 2;
      var closed = false;
      while (i < input.length) {
        final d = input[i];
        if (d == '\\' && i + 1 < input.length) {
          buf.write(_ansiUnescape(input[i + 1]));
          i += 2;
          continue;
        }
        if (d == "'") {
          closed = true;
          i++;
          break;
        }
        buf.write(d);
        i++;
      }
      if (!closed) throw const FormatException("未闭合的 \$' 引号");
      continue;
    }

    if (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
      if (inToken) {
        tokens.add(buf.toString());
        buf.clear();
        inToken = false;
      }
      i++;
      continue;
    }

    buf.write(c);
    inToken = true;
    i++;
  }

  if (inToken) tokens.add(buf.toString());
  return tokens;
}

/// ANSI-C 引号内的简单转义。
String _ansiUnescape(String c) {
  switch (c) {
    case 'n':
      return '\n';
    case 't':
      return '\t';
    case 'r':
      return '\r';
    case '\\':
      return '\\';
    case "'":
      return "'";
    case '"':
      return '"';
    default:
      return c;
  }
}
