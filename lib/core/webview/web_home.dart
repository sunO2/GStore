import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 内置主页的来源。
///
/// 主页本身是一个自包含的 HTML 文件，这样用户可以把它换成在线主题或
/// 自己写的本地 HTML，而不需要改 App。
enum WebHomeMode { builtin, online, local }

const Map<WebHomeMode, String> kWebHomeModeLabels = {
  WebHomeMode.builtin: '内置主页',
  WebHomeMode.online: '在线主题',
  WebHomeMode.local: '本地 HTML',
};

/// 内置主页的伪 origin。
///
/// 用 `loadData` + `baseUrl` 加载：页面是 https 同源、能使用 localStorage，
/// 同时不需要打开 `file://` 权限（避免远程页面借机读取本地文件）。
const String kWebHomeOrigin = 'https://gstore.home';

/// 主页配置：内置 / 在线 URL / 本地 HTML。
class WebHomeConfig {
  const WebHomeConfig({this.mode = WebHomeMode.builtin, this.location = ''});

  static const WebHomeConfig defaults = WebHomeConfig();

  final WebHomeMode mode;

  /// 在线主题的 URL，或本地 HTML 的绝对路径。
  final String location;

  String get trimmedLocation => location.trim();

  bool get isUsable {
    switch (mode) {
      case WebHomeMode.builtin:
        return true;
      case WebHomeMode.online:
        final uri = Uri.tryParse(trimmedLocation);
        return uri != null &&
            (uri.scheme == 'http' || uri.scheme == 'https') &&
            uri.host.isNotEmpty;
      case WebHomeMode.local:
        final path = trimmedLocation;
        if (path.isEmpty) return false;
        final uri = Uri.tryParse(path);
        if (uri != null && uri.scheme == 'file') {
          return File(uri.toFilePath()).existsSync();
        }
        return File(path).existsSync();
    }
  }

  /// 实际加载的地址；内置主页返回 null（由 HTML 数据驱动）。
  String? get entryUrl {
    switch (mode) {
      case WebHomeMode.builtin:
        return null;
      case WebHomeMode.online:
        return isUsable ? trimmedLocation : null;
      case WebHomeMode.local:
        if (!isUsable) return null;
        final path = trimmedLocation;
        return _fileUriFor(path);
    }
  }

  WebHomeConfig copyWith({WebHomeMode? mode, String? location}) =>
      WebHomeConfig(
        mode: mode ?? this.mode,
        location: location ?? this.location,
      );

  Map<String, Object?> toJson() => {
        'mode': mode.name,
        'location': location,
      };

  factory WebHomeConfig.fromJson(Map<String, Object?> json) {
    final name = json['mode']?.toString() ?? '';
    final mode = WebHomeMode.values.firstWhere(
      (m) => m.name == name,
      orElse: () => WebHomeMode.builtin,
    );
    return WebHomeConfig(
      mode: mode,
      location: json['location']?.toString() ?? '',
    );
  }

  static String _fileUriFor(String path) {
    if (path.startsWith('file://')) return path;
    return Uri.file(path).toString();
  }
}

/// 主页配置的持久化。
class WebHomeStore {
  WebHomeStore._();

  static final WebHomeStore instance = WebHomeStore._();

  static const String _key = 'web_home_config_v1';

  WebHomeConfig _config = WebHomeConfig.defaults;
  bool _loaded = false;

  WebHomeConfig get config => _config;
  bool get isLoaded => _loaded;

  Future<void> load({bool force = false}) async {
    if (_loaded && !force) return;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          _config = WebHomeConfig.fromJson(
            decoded.map((key, value) => MapEntry(key.toString(), value)),
          );
        }
      } catch (_) {
        _config = WebHomeConfig.defaults;
      }
    }
    _loaded = true;
  }

  Future<void> save(WebHomeConfig next) async {
    _config = next;
    _loaded = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(next.toJson()));
  }

  Future<void> reset() => save(WebHomeConfig.defaults);

  @visibleForTesting
  Future<void> debugReset() async {
    _config = WebHomeConfig.defaults;
    _loaded = false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }
}

/// 读取内置主页 HTML 模板。
Future<String> loadWebHomeHtml() => rootBundle.loadString('assets/web/home.html');

/// 把用户选择的 HTML 复制进 App 私有目录。
///
/// provider 返回的路径往往是临时缓存，重启后会被清掉，所以本地主页必须先
/// 复制到 `ApplicationSupport/web_home/home.html`。
Future<String> importLocalHomeHtml(String sourcePath) async {
  final directory = Directory(
    '${(await getApplicationSupportDirectory()).path}/web_home',
  );
  await directory.create(recursive: true);
  final target = File('${directory.path}/home.html');
  if (File(sourcePath).absolute.path == target.absolute.path) return target.path;
  return (await File(sourcePath).copy(target.path)).path;
}

/// 把主题变量注入内置主页，避免首帧闪白。
///
/// 运行时主题变化由页面的 `window.__gstoreHome.setTheme` 处理；这里只负责
/// 文档刚创建时的那一帧。
String buildWebHomeHtml({
  required Map<String, String> css,
  required bool dark,
  String? placeholder,
}) {
  final variables = StringBuffer(':root{');
  css.forEach((key, value) => variables.write('$key:$value;'));
  variables.write('}');

  var html = _cachedTemplate;
  if (html.isEmpty) return html;

  html = html.replaceFirst('<!--__GS_THEME__-->', '<style>$variables</style>');
  if (dark) {
    html = html.replaceFirst('data-theme="light"', 'data-theme="dark"');
  }
  if (placeholder != null && placeholder.isNotEmpty) {
    html = html.replaceFirst(
      '搜索或输入网址',
      const HtmlEscape(HtmlEscapeMode.element).convert(placeholder),
    );
  }
  return html;
}

/// 模板缓存：主页可以被反复重建（返回主页 / 切换主题），避免重复读 asset。
String _cachedTemplate = '';

/// 载入模板到缓存。启动时调用一次即可，失败时下次再试。
Future<String> primeWebHomeTemplate() async {
  if (_cachedTemplate.isNotEmpty) return _cachedTemplate;
  _cachedTemplate = await loadWebHomeHtml();
  return _cachedTemplate;
}

/// 是否是内置主页的地址（`https://gstore.home/...`）。
bool isWebHomeUrl(String? url) {
  if (url == null || url.isEmpty) return false;
  return url == kWebHomeOrigin || url.startsWith('$kWebHomeOrigin/');
}
