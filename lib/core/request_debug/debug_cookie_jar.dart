/// 「请求调试」Cookie jar（纯逻辑，可独立单测）。
///
/// **决策**（见 `.omo/plans/proxy-http-capture.md` todo 26）：Cookie jar
/// **手写**，不引第三方 cookie 库——`package:http` 只做传输，`Set-Cookie`
/// 的解析 / 按 host 存储 / 回发 / 清除全部在本文件完成，便于 UI 展示与单测。
///
/// 采用 `DebugCookie{name,value,domain,path}`（todo 25 模型，不重定义）作为
/// 对外视图；解析到的 `Expires` / `Max-Age` 仅用于**过期剔除**（过期或
/// `Max-Age<=0` 即删除），不落库（模型无该字段）。
library;

import 'dart:io' show HttpDate;

import 'debug_models.dart';

/// 一个已解析且带内部过期时间的 cookie（私有存储形态）。
class _StoredCookie {
  _StoredCookie(this.cookie, this.expiresAt);

  final DebugCookie cookie;

  /// `null` = 会话 cookie（不过期）。
  final DateTime? expiresAt;

  bool get isExpired {
    final at = expiresAt;
    return at != null && !at.isAfter(DateTime.now());
  }
}

/// 手写 Cookie jar：解析 `Set-Cookie`、按 host 存、可查看 / 清除 / 回发。
class DebugCookieJar {
  /// host（小写）→ cookie 键 → 条目。cookie 键 = `domain|path|name`。
  final Map<String, Map<String, _StoredCookie>> _byHost =
      <String, Map<String, _StoredCookie>>{};

  /// 是否没有任何 cookie（含全部 host）。
  bool get isEmpty => _byHost.values.every((m) => m.isEmpty);

  /// 从某个 host 的响应头收集 `Set-Cookie` 并存入 jar。
  ///
  /// [headers] 为响应头映射（键大小写不敏感）；`set-cookie` 值可为多元素
  /// （每条一个 cookie），也可为 `package:http` 合并后的单串（内部再切分）。
  void store(String host, Map<String, List<String>> responseHeaders) {
    final rawValues = _headerValues(responseHeaders, 'set-cookie');
    if (rawValues.isEmpty) return;
    final hostKey = host.toLowerCase();
    final bucket = _byHost.putIfAbsent(hostKey, () => <String, _StoredCookie>{});
    for (final raw in rawValues) {
      for (final stored in _parseStored(raw, defaultDomain: hostKey)) {
        final key = _cookieKey(stored.cookie);
        if (stored.isExpired) {
          bucket.remove(key);
        } else {
          bucket[key] = stored;
        }
      }
    }
    bucket.removeWhere((_, value) => value.isExpired);
    if (bucket.isEmpty) _byHost.remove(hostKey);
  }

  /// 返回发往 [host] 的 `Cookie` 头值（`name=value; name2=value2`）。
  ///
  /// 无匹配 / 全部过期时返回空串。
  String cookieHeaderFor(String host) {
    final pairs = <String>[];
    for (final cookie in cookiesFor(host)) {
      pairs.add('${cookie.name}=${cookie.value}');
    }
    return pairs.join('; ');
  }

  /// 匹配 [host] 的全部未过期 cookie（host 后缀 / domain 匹配）。
  List<DebugCookie> cookiesFor(String host) {
    final hostKey = host.toLowerCase();
    final result = <DebugCookie>[];
    _byHost.forEach((owner, bucket) {
      bucket.removeWhere((_, value) => value.isExpired);
      for (final stored in bucket.values) {
        if (_domainMatches(stored.cookie.domain ?? owner, hostKey)) {
          result.add(stored.cookie);
        }
      }
    });
    _byHost.removeWhere((_, bucket) => bucket.isEmpty);
    return result;
  }

  /// 清空全部 cookie。
  void clear() => _byHost.clear();

  // ==================== 纯解析（静态，可单测） ====================

  /// 解析一条 `Set-Cookie`（可能已被合并多条）为 [DebugCookie] 列表。
  static List<DebugCookie> parseSetCookie(String header) =>
      _parseStored(header).map((e) => e.cookie).toList();

  /// 把 `package:http` 合并的单串切分为多条 `Set-Cookie`。
  ///
  /// 关键点：`Expires=Wed, 21 Oct 2099 07:28:00 GMT` 内的逗号**不得**误切
  /// ——仅当逗号后是一个 `name=` 形态才视为新 cookie 起始。
  static List<String> splitSetCookieHeader(String raw) =>
      _splitJoined(raw);

  // ==================== 私有 ====================

  static List<String> _headerValues(
    Map<String, List<String>> headers,
    String name,
  ) {
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == name) return entry.value;
    }
    return const <String>[];
  }

  static String _cookieKey(DebugCookie cookie) =>
      '${cookie.domain ?? ''}|${cookie.path ?? '/'}|${cookie.name}';

  static bool _domainMatches(String cookieDomain, String host) {
    final d = cookieDomain.toLowerCase().replaceFirst(RegExp(r'^\.'), '');
    if (d.isEmpty) return false;
    return host == d || host.endsWith('.$d');
  }

  static List<_StoredCookie> _parseStored(
    String raw, {
    String? defaultDomain,
  }) {
    final result = <_StoredCookie>[];
    for (final part in _splitJoined(raw)) {
      final stored = _parseOne(part, defaultDomain: defaultDomain);
      if (stored != null) result.add(stored);
    }
    return result;
  }

  static _StoredCookie? _parseOne(String part, {String? defaultDomain}) {
    final trimmed = part.trim();
    if (trimmed.isEmpty) return null;

    final segments = trimmed.split(';');
    final pair = segments.first.trim();
    final eq = pair.indexOf('=');
    if (eq <= 0) return null;
    final name = pair.substring(0, eq).trim();
    if (name.isEmpty) return null;
    final value = pair.substring(eq + 1).trim();

    String? domain;
    String? path;
    DateTime? expiresAt;

    for (var i = 1; i < segments.length; i++) {
      final segment = segments[i].trim();
      if (segment.isEmpty) continue;
      final sep = segment.indexOf('=');
      final attr = (sep < 0 ? segment : segment.substring(0, sep))
          .trim()
          .toLowerCase();
      final attrValue = sep < 0 ? '' : segment.substring(sep + 1).trim();
      switch (attr) {
        case 'domain':
          if (attrValue.isNotEmpty) domain = attrValue.toLowerCase();
          break;
        case 'path':
          if (attrValue.isNotEmpty) path = attrValue;
          break;
        case 'max-age':
          final seconds = int.tryParse(attrValue);
          if (seconds != null) {
            expiresAt = seconds <= 0
                ? DateTime.fromMillisecondsSinceEpoch(0)
                : DateTime.now().add(Duration(seconds: seconds));
          }
          break;
        case 'expires':
          final parsed = _tryParseHttpDate(attrValue);
          if (parsed != null) expiresAt = parsed;
          break;
        default:
          break;
      }
    }

    domain ??= defaultDomain;
    return _StoredCookie(
      DebugCookie(name: name, value: value, domain: domain, path: path),
      expiresAt,
    );
  }

  static DateTime? _tryParseHttpDate(String value) {
    if (value.isEmpty) return null;
    try {
      return HttpDate.parse(value);
    } catch (_) {
      return null;
    }
  }

  static List<String> _splitJoined(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return const <String>[];
    final parts = <String>[];
    var start = 0;
    for (var i = 0; i < raw.length; i++) {
      if (raw.codeUnitAt(i) != _comma) continue;
      if (_looksLikeCookieStart(raw, i + 1)) {
        parts.add(raw.substring(start, i));
        start = i + 1;
      }
    }
    parts.add(raw.substring(start));
    return parts
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList(growable: false);
  }

  static bool _looksLikeCookieStart(String raw, int from) {
    var i = from;
    while (i < raw.length &&
        (raw.codeUnitAt(i) == _space || raw.codeUnitAt(i) == _tab)) {
      i++;
    }
    final nameStart = i;
    while (i < raw.length) {
      final c = raw.codeUnitAt(i);
      if (c == _equals) return i > nameStart;
      if (c == _semicolon || c == _comma) return false;
      if (!_isCookieNameChar(raw[i])) return false;
      i++;
    }
    return false;
  }

  static bool _isCookieNameChar(String ch) {
    if (ch.isEmpty) return false;
    final code = ch.codeUnitAt(0);
    final isDigit = code >= 0x30 && code <= 0x39;
    final isUpper = code >= 0x41 && code <= 0x5A;
    final isLower = code >= 0x61 && code <= 0x7A;
    if (isDigit || isUpper || isLower) return true;
    return const <String>[
      '!', '#', r'$', '%', '&', "'", '*', '+', '-', '.', '^', '_', '`', '|',
      '~',
    ].contains(ch);
  }

  static const int _comma = 0x2C;
  static const int _equals = 0x3D;
  static const int _semicolon = 0x3B;
  static const int _space = 0x20;
  static const int _tab = 0x09;
}
