/// 统一 Cookie 同步接缝（WebView / httpRequest / 请求调试共用）。
///
/// 本文件只定义可序列化模型与端口，不依赖 Flutter / WebView / 存储插件，
/// 便于纯逻辑单测。
library;

/// 一条浏览器语义的 Cookie。
///
/// 与 [DebugCookie] 的区别：这里保留 `Secure` / `HttpOnly` / `SameSite` /
/// 过期时间等属性，用于在 WebView 与原生 HTTP 之间无损同步。
class SyncCookie {
  const SyncCookie({
    required this.name,
    required this.value,
    this.domain,
    this.path = '/',
    this.expiresAt,
    this.hostOnly = true,
    this.secure = false,
    this.httpOnly = false,
    this.sameSite,
  });

  final String name;
  final String value;

  /// Cookie 域；host-only 时等于发起请求的 host。
  final String? domain;

  final String path;

  /// `null` = 会话 Cookie（不过期）。
  final DateTime? expiresAt;

  /// 无 `Domain` 属性 → 只回发到精确 host。
  final bool hostOnly;

  final bool secure;
  final bool httpOnly;

  /// 规范化为 `Strict` / `Lax` / `None`；无法识别为 `null`。
  final String? sameSite;

  bool get isSession => expiresAt == null;

  bool get isExpired {
    final at = expiresAt;
    return at != null && !at.isAfter(DateTime.now());
  }

  SyncCookie copyWith({
    String? name,
    String? value,
    String? domain,
    String? path,
    DateTime? expiresAt,
    bool? hostOnly,
    bool? secure,
    bool? httpOnly,
    String? sameSite,
  }) {
    return SyncCookie(
      name: name ?? this.name,
      value: value ?? this.value,
      domain: domain ?? this.domain,
      path: path ?? this.path,
      expiresAt: expiresAt ?? this.expiresAt,
      hostOnly: hostOnly ?? this.hostOnly,
      secure: secure ?? this.secure,
      httpOnly: httpOnly ?? this.httpOnly,
      sameSite: sameSite ?? this.sameSite,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name,
        'value': value,
        'domain': domain,
        'path': path,
        'expiresAt': expiresAt?.millisecondsSinceEpoch,
        'hostOnly': hostOnly,
        'secure': secure,
        'httpOnly': httpOnly,
        'sameSite': sameSite,
      };

  factory SyncCookie.fromJson(Map<String, dynamic> json) {
    final rawExpires = json['expiresAt'];
    return SyncCookie(
      name: json['name']?.toString() ?? '',
      value: json['value']?.toString() ?? '',
      domain: json['domain']?.toString(),
      path: json['path']?.toString() ?? '/',
      expiresAt: rawExpires is num
          ? DateTime.fromMillisecondsSinceEpoch(rawExpires.toInt())
          : null,
      hostOnly: json['hostOnly'] as bool? ?? true,
      secure: json['secure'] as bool? ?? false,
      httpOnly: json['httpOnly'] as bool? ?? false,
      sameSite: json['sameSite']?.toString(),
    );
  }
}

/// WebView 原生 Cookie 存储适配器。
///
/// 生产实现走 `flutter_inappwebview` 的 `CookieManager`；测试注入内存假实现。
abstract class CookieBridgePort {
  /// 读取对 [uri] 生效的 Cookie（含 HttpOnly，取决于 WebView 版本）。
  ///
  /// 返回 `null` 表示读取失败（区别于“成功但没有 Cookie”）。失败时上层
  /// 不做删除/对账，避免误删 httpRequest 侧刚写入的 Cookie。
  Future<List<SyncCookie>?> readCookies(Uri uri);

  /// 写入一条 Cookie 到 WebView（用于把 httpRequest 的 Set-Cookie 回灌）。
  Future<void> writeCookie(Uri uri, SyncCookie cookie);

  /// 从 WebView 删除一条 Cookie。
  Future<void> deleteCookie(Uri uri, SyncCookie cookie);

  /// 清空 WebView 的全部 Cookie。
  Future<void> deleteAllCookies();
}

/// Cookie 持久化端口（生产为安全存储）。
abstract class CookiePersistencePort {
  Future<String?> read();

  Future<void> write(String value);

  Future<void> clear();
}

/// `httpRequest` / 请求调试发送器使用的 Cookie 同步端口。
///
/// 实现必须保证：
/// - 只返回对目标 [Uri] 生效的 Cookie；
/// - 显式 `Cookie` 头优先于 jar/ WebView；
/// - 响应 `Set-Cookie` 写回 jar 与 WebView，但不把 `Set-Cookie` 回灌给模型。
abstract class CookieSyncPort {
  /// 首次使用前加载持久化 Cookie。
  Future<void> ensureLoaded();

  /// 生成最终 `Cookie` 头（显式 + WebView 实时 + 持久化）。
  Future<String> cookieHeaderForUri(Uri uri, {String explicit = ''});

  /// 收集响应头中的 `Set-Cookie` 并同步到 jar / WebView。
  Future<void> captureResponse(Uri uri, Map<String, String> headers);
}
