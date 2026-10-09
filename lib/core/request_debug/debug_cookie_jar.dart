/// 「请求调试」Cookie jar（纯逻辑，可独立单测）。
///
/// **决策**（见 `.omo/plans/proxy-http-capture.md` todo 26）：Cookie jar
/// **手写**，不引第三方 cookie 库——`package:http` 只做传输，`Set-Cookie`
/// 的解析 / 按 host 存储 / 回发 / 清除全部在本文件完成，便于 UI 展示与单测。
///
/// 采用 `DebugCookie{name,value,domain,path}`（todo 25 模型，不重定义）作为
/// 对外视图；解析到的 `Expires` / `Max-Age` 仅用于**过期剔除**（过期或
/// `Max-Age<=0` 即删除），不落库（模型无该字段）。按 RFC 6265：
/// `Max-Age` **优先于** `Expires`（与属性顺序无关）。`Domain` / `Path` /
/// `Secure` / `HttpOnly` / `SameSite` 在内部按 RFC 6265 校验/存储：
///
/// * **Domain**：无 `Domain` = host-only（仅回发到原 host）；有 `Domain` 时
///   必须与请求 host domain-match，否则**拒绝**（防跨站注入）；拒绝
///   单标签 / 已知两段公共后缀（`.com` / `.co.uk`）防 supercookie；
///   `Domain=localhost`（与 host 相等）、尾点、IDN 会被规范化。
/// * **Path**：按 RFC 6265 默认路径与路径匹配，只回发到匹配路径。
/// * **Secure**：仅经 https 回发；`HttpOnly` 服务端语义（不在 JS 暴露），
///   对发送无影响（解析后忽略）；`SameSite` 解析并存储（模型无字段，内部保留）。
/// * **跨子域同名**：回发时按「名 + Path」去重，避免重复发送。
library;

import 'dart:io' show HttpDate;

import 'debug_models.dart';

/// 一个已解析且带内部过期时间的 cookie（私有存储形态）。
class _StoredCookie {
  _StoredCookie(
    this.cookie,
    this.expiresAt, {
    this.hostOnly = false,
    this.secure = false,
    this.sameSite,
  });

  final DebugCookie cookie;

  /// `null` = 会话 cookie（不过期）。
  final DateTime? expiresAt;

  /// 无 `Domain` 属性 → host-only（仅精确匹配原 host）。
  final bool hostOnly;

  /// 带 `Secure` 属性 → 仅经 https 回发。
  final bool secure;

  /// `SameSite` 属性（规范化为 `Strict` / `Lax` / `None`）；无 / 非法为 `null`。
  ///
  /// 模型 [DebugCookie] 无该字段，故仅内部存储，供诊断 / 未来回发策略使用。
  final String? sameSite;

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
  /// [path] 为**发起请求的路径**，用于计算缺省 `Path`（RFC 6265 默认路径）。
  ///
  /// 安全：带 `Domain` 但与该请求 host 不 domain-match 的 cookie 一律丢弃
  /// （阻止任意响应向无关 host 注入 cookie）；无 `Domain` 的 cookie 记为
  /// host-only（不回发到子域）。
  void store(
    String host,
    Map<String, List<String>> responseHeaders, {
    String path = '/',
  }) {
    final rawValues = _headerValues(responseHeaders, 'set-cookie');
    if (rawValues.isEmpty) return;
    final hostKey = _canonicalHost(host);
    final defaultPath = _defaultPath(path);
    final bucket = _byHost.putIfAbsent(hostKey, () => <String, _StoredCookie>{});
    for (final raw in rawValues) {
      for (final stored in _parseStored(
        raw,
        defaultDomain: hostKey,
        defaultPath: defaultPath,
      )) {
        if (!_isAllowedForHost(stored, hostKey)) continue;
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

  /// 返回发往 [host] + [path] 的 `Cookie` 头值（`name=value; name2=value2`）。
  ///
  /// [secure] 表示本次请求是否 https；非 https 时不回发 `Secure` cookie。
  /// 无匹配 / 全部过期时返回空串。
  String cookieHeaderFor(String host, {String path = '/', bool secure = false}) {
    // 跨子域同名去重：同名 + 同 Path 只保留一个（最新存储者胜出，等价于
    // RFC 6265 单存储覆盖语义）；同名但不同 Path 仍各自保留。
    final order = <String>[];
    final byKey = <String, String>{};
    for (final stored in _collect(host, includeSecure: secure)) {
      final cookiePath = _cookiePath(stored.cookie);
      if (!_pathMatches(path, cookiePath)) continue;
      final dedupKey = '${stored.cookie.name}\u0000$cookiePath';
      if (!byKey.containsKey(dedupKey)) order.add(dedupKey);
      byKey[dedupKey] = '${stored.cookie.name}=${stored.cookie.value}';
    }
    return order.map((key) => byKey[key]!).join('; ');
  }

  /// 返回已存 cookie 的 `SameSite` 值（`Strict` / `Lax` / `None`）；无则 `null`。
  ///
  /// 模型 [DebugCookie] 无该字段，此访问器用于诊断与测试（T12）。
  String? sameSiteFor(String host, String name) {
    final hostKey = _canonicalHost(host);
    for (final bucket in _byHost.values) {
      for (final stored in bucket.values) {
        if (stored.cookie.name != name) continue;
        if (!_hostMatches(stored, hostKey)) continue;
        return stored.sameSite;
      }
    }
    return null;
  }

  /// 匹配 [host] 的全部未过期 cookie（host 后缀 / domain 匹配）。
  ///
  /// [path] 非空时额外做路径匹配。用于 UI 展示（含 `Secure` cookie 视图）。
  List<DebugCookie> cookiesFor(String host, {String? path}) {
    final result = <DebugCookie>[];
    for (final stored in _collect(host, includeSecure: true)) {
      if (path != null && !_pathMatches(path, _cookiePath(stored.cookie))) {
        continue;
      }
      result.add(stored.cookie);
    }
    return result;
  }

  /// 清空全部 cookie。
  void clear() => _byHost.clear();

  /// 清除某个 host 桶内的全部 cookie（Cookie 管理界面用）。
  ///
  /// 仅移除以 [host] 为**存储键**的桶（与 [snapshot] 的分组一致）。
  void clearHost(String host) => _byHost.remove(_canonicalHost(host));

  /// 可列出的快照：host → 未过期 cookie 列表（Cookie 管理界面用）。
  ///
  /// host 为**存储该 cookie 的请求 host**（host-only cookie 的 `domain` 即此
  /// host；带 `Domain` 的 cookie 归入设置它的 host 桶）。返回的 map 与列表
  /// 均为不可变视图，修改快照不影响 jar；过期条目在生成时被剔除。
  Map<String, List<DebugCookie>> snapshot() {
    final result = <String, List<DebugCookie>>{};
    for (final entry in _byHost.entries) {
      final bucket = entry.value;
      bucket.removeWhere((_, value) => value.isExpired);
      if (bucket.isEmpty) continue;
      result[entry.key] =
          List<DebugCookie>.unmodifiable(bucket.values.map((s) => s.cookie));
    }
    _byHost.removeWhere((_, bucket) => bucket.isEmpty);
    return Map<String, List<DebugCookie>>.unmodifiable(result);
  }

  // ==================== Cookie 头合并（静态，可单测） ====================

  /// 合并「显式 `Cookie` 头」与「jar 生成的 `Cookie` 头」。
  ///
  /// 语义：**先出现者优先**（故 [explicit] 中的条目优先于 [jar]），并按
  /// cookie 名去重，避免同名 cookie 重复发送。空串来源被忽略；两者皆空返回
  /// 空串。形如 `name=value; name2=value2`。
  static String mergeCookieHeader(String explicit, String jar) {
    final parts = <String>[];
    final seen = <String>{};
    void add(String header) {
      for (final raw in header.split(';')) {
        final pair = raw.trim();
        if (pair.isEmpty) continue;
        final eq = pair.indexOf('=');
        final name = (eq <= 0 ? pair : pair.substring(0, eq)).trim();
        if (name.isEmpty || !seen.add(name)) continue;
        parts.add(pair);
      }
    }

    add(explicit);
    add(jar);
    return parts.join('; ');
  }

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

  /// 规范化 host / domain：小写、去前导与尾随 `.`、IDN 百分号编码对齐。
  static String _normalizeDomain(String domain) => _canonicalHost(domain);

  /// host / domain 的规范形态（供存储键与匹配统一使用）。
  ///
  /// * 小写；
  /// * 去掉前导 / 尾随 `.`（`Domain=.example.com.` → `example.com`）；
  /// * 非 ASCII（IDN）按 UTF-8 百分号编码，与 `Uri.host` 对齐（Dart 的
  ///   `Uri.host` 不做 punycode，仅百分号编码；故二者可比较）。
  static String _canonicalHost(String host) {
    var value = host.trim();
    while (value.startsWith('.')) {
      value = value.substring(1);
    }
    while (value.endsWith('.')) {
      value = value.substring(0, value.length - 1);
    }
    if (value.isEmpty) return value;
    if (!_isAscii(value)) {
      try {
        // 复用 Uri 的 host 规范化（UTF-8 百分号编码），保证两侧一致。
        value = Uri.parse('http://$value').host;
      } catch (_) {
        // 非法字符：保留原值，后续 domain-match 阶段会被拒，不抛。
      }
    }
    // 最后统一小写：规范化 %XX 转义的大小写（十六进制大小写不敏感），
    // 使 Unicode 域与百分号编码 host 两侧得到同一形态。
    return value.toLowerCase();
  }

  static bool _isAscii(String value) {
    for (var i = 0; i < value.length; i++) {
      if (value.codeUnitAt(i) > 0x7F) return false;
    }
    return true;
  }

  /// RFC 6265 domain-match：host 等于 domain 或以 `.domain` 结尾。
  static bool _domainMatches(String cookieDomain, String host) {
    final d = _normalizeDomain(cookieDomain);
    if (d.isEmpty) return false;
    return host == d || host.endsWith('.$d');
  }

  /// 是否允许把该 cookie 绑定到 [host]（即设置它的请求 host）。
  ///
  /// * host-only（无 `Domain`）：总是允许——它已限定在原 host。
  /// * `Domain` 与 [host] 完全相等：允许（覆盖 `Domain=localhost` 等开发场景）。
  /// * 单标签 / 已知两段公共后缀（`.com` / `.co.uk`）：拒绝，防 supercookie。
  /// * 其余：必须与 [host] domain-match。
  static bool _isAllowedForHost(_StoredCookie stored, String host) {
    if (stored.hostOnly) return true;
    final domain = _normalizeDomain(stored.cookie.domain ?? '');
    if (domain.isEmpty) return false;
    if (domain == host) return true;
    if (!domain.contains('.')) return false;
    if (_isKnownPublicSuffix(domain)) return false;
    return _domainMatches(domain, host);
  }

  /// 精简公共后缀集合（**非完整 PSL**，无第三方依赖）。
  ///
  /// 仅覆盖常见易被用作 supercookie 的后缀；单标签 TLD 已由上一步拒绝。
  /// 未收录的公共后缀无法识别——不要在安全边界上依赖本集合的完备性。
  static bool _isKnownPublicSuffix(String domain) =>
      _knownPublicSuffixes.contains(_normalizeDomain(domain));

  static const Set<String> _knownPublicSuffixes = <String>{
    // 多标签公共后缀（两段 / 三段）。
    'co.uk', 'org.uk', 'ac.uk', 'gov.uk',
    'com.cn', 'net.cn', 'org.cn', 'gov.cn',
    'com.tw', 'com.hk', 'co.jp', 'co.kr',
    'com.au', 'com.br', 'com.mx',
    'github.io', 'pages.dev', 'vercel.app', 'netlify.app',
  };

  /// 判断已存 cookie 是否对请求 [host] 生效。
  static bool _hostMatches(_StoredCookie stored, String host) {
    if (stored.hostOnly) {
      return _normalizeDomain(stored.cookie.domain ?? '') == host;
    }
    return _domainMatches(stored.cookie.domain ?? '', host);
  }

  /// 收集对 [host] 生效的未过期 cookie；[includeSecure] 为 false 时排除
  /// `Secure` cookie（http 请求）。
  List<_StoredCookie> _collect(String host, {required bool includeSecure}) {
    final hostKey = _canonicalHost(host);
    final result = <_StoredCookie>[];
    _byHost.forEach((_, bucket) {
      bucket.removeWhere((_, value) => value.isExpired);
      for (final stored in bucket.values) {
        if (!_hostMatches(stored, hostKey)) continue;
        if (stored.secure && !includeSecure) continue;
        result.add(stored);
      }
    });
    _byHost.removeWhere((_, bucket) => bucket.isEmpty);
    return result;
  }

  static String _cookiePath(DebugCookie cookie) => cookie.path ?? '/';

  /// RFC 6265 默认路径：取请求路径去除最后一段的目录；无 `/` 段时为 `/`。
  static String _defaultPath(String requestPath) {
    if (requestPath.isEmpty || !requestPath.startsWith('/')) return '/';
    final lastSlash = requestPath.lastIndexOf('/');
    if (lastSlash <= 0) return '/';
    return requestPath.substring(0, lastSlash);
  }

  /// RFC 6265 path-match。
  static bool _pathMatches(String requestPath, String cookiePath) {
    final req = requestPath.isEmpty ? '/' : requestPath;
    final cp = cookiePath.isEmpty ? '/' : cookiePath;
    if (req == cp) return true;
    if (!req.startsWith(cp)) return false;
    if (cp.endsWith('/')) return true;
    return req.codeUnitAt(cp.length) == _slash;
  }

  static List<_StoredCookie> _parseStored(
    String raw, {
    String? defaultDomain,
    String? defaultPath,
  }) {
    final result = <_StoredCookie>[];
    for (final part in _splitJoined(raw)) {
      final stored = _parseOne(
        part,
        defaultDomain: defaultDomain,
        defaultPath: defaultPath,
      );
      if (stored != null) result.add(stored);
    }
    return result;
  }

  static _StoredCookie? _parseOne(
    String part, {
    String? defaultDomain,
    String? defaultPath,
  }) {
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
    String? sameSite;
    DateTime? expiresAt;
    DateTime? maxAgeAt;
    var domainSpecified = false;
    var maxAgeSpecified = false;
    var secure = false;

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
          if (attrValue.isNotEmpty) {
            domain = attrValue.toLowerCase();
            domainSpecified = true;
          }
          break;
        case 'path':
          if (attrValue.isNotEmpty) path = attrValue;
          break;
        case 'secure':
          secure = true;
          break;
        case 'httponly':
          // 服务端语义（不在 JS 暴露），对回发无影响：解析后忽略。
          break;
        case 'samesite':
          sameSite = _normalizeSameSite(attrValue);
          break;
        case 'max-age':
          final seconds = int.tryParse(attrValue);
          if (seconds != null) {
            maxAgeSpecified = true;
            maxAgeAt = seconds <= 0
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

    // RFC 6265 §4.1.2.2：`Max-Age` 优先于 `Expires`，与属性出现顺序无关。
    final effectiveExpiresAt = maxAgeSpecified ? maxAgeAt : expiresAt;

    // 无 Domain → host-only，domain 绑定到设置它的请求 host；有 Domain 时
    // 保留原始声明（store 阶段再做 domain-match 校验）。
    final hostOnly = !domainSpecified;
    domain ??= defaultDomain;
    path ??= defaultPath;
    return _StoredCookie(
      DebugCookie(name: name, value: value, domain: domain, path: path),
      effectiveExpiresAt,
      hostOnly: hostOnly,
      secure: secure,
      sameSite: sameSite,
    );
  }

  /// 规范化 `SameSite` 取值（大小写不敏感）为 `Strict` / `Lax` / `None`；
  /// 未知 / 空值返回 `null`。
  static String? _normalizeSameSite(String value) {
    switch (value.trim().toLowerCase()) {
      case 'strict':
        return 'Strict';
      case 'lax':
        return 'Lax';
      case 'none':
        return 'None';
      default:
        return null;
    }
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
  static const int _slash = 0x2F;
  static const int _equals = 0x3D;
  static const int _semicolon = 0x3B;
  static const int _space = 0x20;
  static const int _tab = 0x09;
}
