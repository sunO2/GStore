/// 「请求调试」URL 查询编解码（纯函数，无 UI）。
///
/// 目标：把 URL 的查询串与「参数行」合成为最终 URL，且**不破坏** `{{var}}`
/// 占位符——Dart 的 `Uri` 会把花括号百分号编码（`{{host}}` → `%7B%7Bhost%7D%7D`），
/// 直接走 `Uri.queryParameters` 往返会永久污染用户输入。因此解析 / 重建**全部
/// 手动字符扫描**，只有最终交给 HTTP 客户端的 [buildUri] 才构造 [Uri]。
///
/// 关键不变量：
/// - [parseUrlQuery] / [rebuildUrl] **绝不抛异常**、**绝不使用 `Uri.parse`**、
///   **绝不解析 `{{var}}`**；仅百分号解码/编码，`+` 一律按字面量处理。
/// - [rebuildUrl] 仅编码保留字符 `&` `=` `#` `%` 与空格（→ `%20`），其余原样，
///   因此 `{{host}}` 原样保留、可被 [resolveEnv] 在发送前替换。
/// - [mergeParams] 按名分组：覆盖组**顶替**基础组并**保留基础位置**，未覆盖的
///   基础名保持原值/位置，覆盖中新出现的名字按 override 顺序**追加**。
///
/// 与 [buildUri] 的分工：`buildUri` 允许（也必然）对花括号百分号编码——[Uri]
/// 无法持有字面 `{{var}}`；「原样 / 不编码 / 不抛」的保证只属于
/// [parseUrlQuery] / [rebuildUrl]。
library;

import 'dart:convert';

import 'debug_models.dart';

/// [parseUrlQuery] 的结果：[base]（不含查询与 fragment）、有序参数、fragment。
class QueryParseResult {
  const QueryParseResult({
    required this.base,
    required this.params,
    this.fragment,
  });

  /// 去掉查询串（`?...`）与 fragment（`#...`）后的部分。
  final String base;

  /// 按出现顺序解析出的参数（解析行 [DebugQueryParam.enabled] 恒为 `true`）。
  final List<DebugQueryParam> params;

  /// `#` 之后的原文；无 `#` 时为 `null`。
  final String? fragment;
}

/// 解析 [url] 的查询串（**手动扫描**，绝不 `Uri.parse`，绝不抛）。
///
/// 处理顺序：先按第一个 `#` 切出 [QueryParseResult.fragment]，再在剩余部分按
/// 第一个 `?` 切出 base 与查询串。查询串以 `&` / `;` 分隔，每段以**第一个** `=`
/// 分为名/值；无 `=` 视为无值键（`value = ''`）。名与值分别百分号解码，`+`
/// 按字面量保留（**不**转为空格）。
///
/// 任何畸形输入（非法 `%XX`、非法 UTF-8 百分号序列等）都回退为
/// `base = url`、空参数、无 fragment，**不抛异常**。
QueryParseResult parseUrlQuery(String url) {
  try {
    String? fragment;
    var rest = url;
    final hash = url.indexOf('#');
    if (hash >= 0) {
      fragment = url.substring(hash + 1);
      rest = url.substring(0, hash);
    }

    var base = rest;
    final params = <DebugQueryParam>[];
    final question = rest.indexOf('?');
    if (question >= 0) {
      base = rest.substring(0, question);
      _parseQuery(rest.substring(question + 1), params);
    }
    return QueryParseResult(base: base, params: params, fragment: fragment);
  } catch (_) {
    return QueryParseResult(
      base: url,
      params: const <DebugQueryParam>[],
      fragment: null,
    );
  }
}

/// 手动拼装 URL：`base` +（可选）`?query` +（可选）`#fragment`。
///
/// - 查询参数按给定顺序输出，重复名保留；
/// - 值为空时输出无值键（仅 `name`），非空时输出 `name=value`；
/// - `{{...}}` 原样输出；仅百分号编码保留字符 `&` `=` `#` `%` 与空格
///   （→ `%20`），`+` 保持字面量；
/// - 查询串永远在 fragment **之前**。
String rebuildUrl(
  String base,
  String? fragment,
  List<DebugQueryParam> params,
) {
  final buffer = StringBuffer(base);
  if (params.isNotEmpty) {
    buffer.write('?');
    for (var i = 0; i < params.length; i++) {
      if (i > 0) buffer.write('&');
      final param = params[i];
      buffer.write(_encode(param.name));
      if (param.value.isNotEmpty) {
        buffer.write('=');
        buffer.write(_encode(param.value));
      }
    }
  }
  if (fragment != null) {
    buffer.write('#');
    buffer.write(fragment);
  }
  return buffer.toString();
}

/// 按名合并 [base] 与 [overrides]（有序分组）。
///
/// - 被覆盖的名字：整个 override 值组**顶替** base 值组，占用 base 中的**首个
///   出现位置**；
/// - 仅存在于 base 的名字：保持原值组与位置；
/// - 仅存在于 overrides 的名字：按 override 中的首次出现顺序**追加**。
List<DebugQueryParam> mergeParams(
  List<DebugQueryParam> base,
  List<DebugQueryParam> overrides,
) {
  if (overrides.isEmpty) return List<DebugQueryParam>.of(base);

  final overrideGroups = <String, List<DebugQueryParam>>{};
  final overrideOrder = <String>[];
  for (final param in overrides) {
    final group = overrideGroups[param.name];
    if (group == null) {
      overrideGroups[param.name] = <DebugQueryParam>[param];
      overrideOrder.add(param.name);
    } else {
      group.add(param);
    }
  }

  final result = <DebugQueryParam>[];
  final emitted = <String>{};
  final baseNames = <String>{};
  for (final param in base) {
    if (!baseNames.add(param.name)) continue;
    final override = overrideGroups[param.name];
    if (override != null) {
      result.addAll(override);
      emitted.add(param.name);
    } else {
      result.addAll(base.where((p) => p.name == param.name));
    }
  }
  for (final name in overrideOrder) {
    if (emitted.add(name)) {
      result.addAll(overrideGroups[name]!);
    }
  }
  return result;
}

/// 把 [url] 与启用参数合并为最终 [Uri]（query 在 fragment 之前）。
///
/// 等价于：`mergeParams(parseUrlQuery(url).params, 启用且非空的 params)` 后
/// 重建成字符串并 [Uri.parse]。注意 [Uri] 无法持有字面 `{{var}}`——此函数会
/// 将花括号百分号编码（与既有行为一致）；如需保留占位符请改用
/// [parseUrlQuery] / [rebuildUrl]。
Uri buildUri(String url, List<DebugQueryParam> params) {
  final parsed = parseUrlQuery(url);
  final enabled = params.where((p) => p.enabled && p.name.isNotEmpty);
  final merged = mergeParams(parsed.params, enabled.toList());
  return Uri.parse(rebuildUrl(parsed.base, parsed.fragment, merged));
}

// ==================== 手动解析 / 编码辅助 ====================

/// 把查询串按 `&` / `;` 切段并写入 [out]（跳过空段）。
void _parseQuery(String query, List<DebugQueryParam> out) {
  var start = 0;
  for (var i = 0; i <= query.length; i++) {
    final atEnd = i == query.length;
    final isSeparator = !atEnd &&
        (query.codeUnitAt(i) == 0x26 /* & */ ||
            query.codeUnitAt(i) == 0x3B /* ; */);
    if (!atEnd && !isSeparator) continue;
    if (i > start) {
      out.add(_parsePair(query.substring(start, i)));
    }
    start = i + 1;
  }
}

DebugQueryParam _parsePair(String piece) {
  final equals = piece.indexOf('=');
  if (equals < 0) {
    return DebugQueryParam(name: _percentDecode(piece));
  }
  return DebugQueryParam(
    name: _percentDecode(piece.substring(0, equals)),
    value: _percentDecode(piece.substring(equals + 1)),
  );
}

/// 手动百分号解码（支持 UTF-8 多字节；`+` 原样保留）。
///
/// 非法 `%XX` 或非法 UTF-8 序列抛 [FormatException]，由 [parseUrlQuery] 兜底。
String _percentDecode(String input) {
  if (!input.contains('%')) return input;
  final out = StringBuffer();
  final bytes = <int>[];
  void flush() {
    if (bytes.isEmpty) return;
    out.write(utf8.decode(bytes));
    bytes.clear();
  }

  var i = 0;
  while (i < input.length) {
    final unit = input.codeUnitAt(i);
    if (unit == 0x25 /* % */) {
      if (i + 2 >= input.length) {
        throw const FormatException('malformed percent-encoding');
      }
      final hi = _hexValue(input.codeUnitAt(i + 1));
      final lo = _hexValue(input.codeUnitAt(i + 2));
      if (hi < 0 || lo < 0) {
        throw const FormatException('malformed percent-encoding');
      }
      bytes.add((hi << 4) | lo);
      i += 3;
    } else {
      // 字面量（含 `+`）：先落地已累积的百分号字节，再原样写出该字符。
      flush();
      if (unit >= 0xD800 && unit <= 0xDBFF && i + 1 < input.length) {
        out.writeCharCode(unit);
        out.writeCharCode(input.codeUnitAt(i + 1));
        i += 2;
      } else {
        out.writeCharCode(unit);
        i += 1;
      }
    }
  }
  flush();
  return out.toString();
}

int _hexValue(int code) {
  if (code >= 0x30 && code <= 0x39) return code - 0x30; // 0-9
  if (code >= 0x41 && code <= 0x46) return code - 0x41 + 10; // A-F
  if (code >= 0x61 && code <= 0x66) return code - 0x61 + 10; // a-f
  return -1;
}

/// 仅编码保留字符 `&` `=` `#` `%` 与空格（→ `%20`）；其余（含 `+`、`{` `}`）原样。
///
/// `%` 必须编码为 `%25`：否则值中的字面 `%` 会与后续解析的百分号转义冲突，
/// 导致 `parseUrlQuery` 回退（丢失全部参数）。修复此点保证含 `%` 的值往返不损坏。
String _encode(String input) {
  if (!input.contains(_reservedPattern)) return input;
  final buffer = StringBuffer();
  for (final rune in input.runes) {
    if (rune == 0x26 /* & */ ||
        rune == 0x3D /* = */ ||
        rune == 0x23 /* # */ ||
        rune == 0x25 /* % */ ||
        rune == 0x20 /* space */) {
      buffer.write('%');
      buffer.write(rune.toRadixString(16).toUpperCase().padLeft(2, '0'));
    } else {
      buffer.writeCharCode(rune);
    }
  }
  return buffer.toString();
}

final RegExp _reservedPattern = RegExp(r'[%=&# ]');
