import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 内置浏览器的默认搜索引擎。
enum WebSearchEngine { bing, baidu, google, duckduckgo, custom }

const Map<WebSearchEngine, String> kSearchEngineLabels = {
  WebSearchEngine.bing: '必应',
  WebSearchEngine.baidu: '百度',
  WebSearchEngine.google: 'Google',
  WebSearchEngine.duckduckgo: 'DuckDuckGo',
  WebSearchEngine.custom: '自定义',
};

/// 各引擎的搜索地址模板（`%s` 会被替换为 URL 编码后的关键词）。
const Map<WebSearchEngine, String> kSearchEngineTemplates = {
  WebSearchEngine.bing: 'https://www.bing.com/search?q=%s',
  WebSearchEngine.baidu: 'https://www.baidu.com/s?wd=%s',
  WebSearchEngine.google: 'https://www.google.com/search?q=%s',
  WebSearchEngine.duckduckgo: 'https://duckduckgo.com/?q=%s',
};

/// 内置浏览器的可配置项（WebView 环境 / 显示 / 隐私）。
///
/// 后续新增能力（广告拦截、翻译、下载接管等）继续往这里加字段，
/// 通过 [WebViewSettings.copyWith] + JSON 持久化即可，不影响已有配置。
class WebViewSettings {
  const WebViewSettings({
    this.searchEngine = WebSearchEngine.bing,
    this.customSearchTemplate = '',
    this.desktopMode = false,
    this.nightMode = false,
    this.textZoom = 100,
    this.loadImages = true,
    this.javaScriptEnabled = true,
    this.cacheEnabled = true,
    this.thirdPartyCookies = true,
  });

  static const WebViewSettings defaults = WebViewSettings();

  final WebSearchEngine searchEngine;

  /// 自定义搜索模板，必须包含 `%s`。
  final String customSearchTemplate;

  final bool desktopMode;
  final bool nightMode;

  /// 网页正文缩放百分比（70–200）。
  final int textZoom;

  final bool loadImages;
  final bool javaScriptEnabled;
  final bool cacheEnabled;
  final bool thirdPartyCookies;

  /// 实际生效的搜索地址模板。
  String get searchTemplate {
    final custom = customSearchTemplate.trim();
    if (searchEngine == WebSearchEngine.custom && custom.contains('%s')) {
      return custom;
    }
    return kSearchEngineTemplates[searchEngine == WebSearchEngine.custom
        ? WebSearchEngine.bing
        : searchEngine]!;
  }

  /// 把关键词拼成搜索地址。
  String searchUrl(String query) =>
      searchTemplate.replaceFirst('%s', Uri.encodeComponent(query.trim()));

  WebViewSettings copyWith({
    WebSearchEngine? searchEngine,
    String? customSearchTemplate,
    bool? desktopMode,
    bool? nightMode,
    int? textZoom,
    bool? loadImages,
    bool? javaScriptEnabled,
    bool? cacheEnabled,
    bool? thirdPartyCookies,
  }) {
    return WebViewSettings(
      searchEngine: searchEngine ?? this.searchEngine,
      customSearchTemplate: customSearchTemplate ?? this.customSearchTemplate,
      desktopMode: desktopMode ?? this.desktopMode,
      nightMode: nightMode ?? this.nightMode,
      textZoom: (textZoom ?? this.textZoom).clamp(70, 200),
      loadImages: loadImages ?? this.loadImages,
      javaScriptEnabled: javaScriptEnabled ?? this.javaScriptEnabled,
      cacheEnabled: cacheEnabled ?? this.cacheEnabled,
      thirdPartyCookies: thirdPartyCookies ?? this.thirdPartyCookies,
    );
  }

  Map<String, Object?> toJson() => {
        'searchEngine': searchEngine.name,
        'customSearchTemplate': customSearchTemplate,
        'desktopMode': desktopMode,
        'nightMode': nightMode,
        'textZoom': textZoom,
        'loadImages': loadImages,
        'javaScriptEnabled': javaScriptEnabled,
        'cacheEnabled': cacheEnabled,
        'thirdPartyCookies': thirdPartyCookies,
      };

  factory WebViewSettings.fromJson(Map<String, Object?> json) {
    final engineName = json['searchEngine']?.toString() ?? '';
    final engine = WebSearchEngine.values.firstWhere(
      (e) => e.name == engineName,
      orElse: () => WebSearchEngine.bing,
    );
    return WebViewSettings(
      searchEngine: engine,
      customSearchTemplate: json['customSearchTemplate']?.toString() ?? '',
      desktopMode: json['desktopMode'] as bool? ?? false,
      nightMode: json['nightMode'] as bool? ?? false,
      textZoom: ((json['textZoom'] as num?)?.toInt() ?? 100).clamp(70, 200),
      loadImages: json['loadImages'] as bool? ?? true,
      javaScriptEnabled: json['javaScriptEnabled'] as bool? ?? true,
      cacheEnabled: json['cacheEnabled'] as bool? ?? true,
      thirdPartyCookies: json['thirdPartyCookies'] as bool? ?? true,
    );
  }
}

/// 浏览器设置的持久化（SharedPreferences）。
class WebViewSettingsStore {
  WebViewSettingsStore._();

  static final WebViewSettingsStore instance = WebViewSettingsStore._();

  static const String _key = 'web_view_settings_v1';

  WebViewSettings _settings = WebViewSettings.defaults;
  bool _loaded = false;

  WebViewSettings get settings => _settings;
  bool get isLoaded => _loaded;

  Future<void> load({bool force = false}) async {
    if (_loaded && !force) return;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          _settings = WebViewSettings.fromJson(
            decoded.map((key, value) => MapEntry(key.toString(), value)),
          );
        }
      } catch (_) {
        _settings = WebViewSettings.defaults;
      }
    }
    _loaded = true;
  }

  Future<void> save(WebViewSettings next) async {
    _settings = next;
    _loaded = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(next.toJson()));
  }

  Future<void> reset() => save(WebViewSettings.defaults);

  @visibleForTesting
  Future<void> debugReset() async {
    _settings = WebViewSettings.defaults;
    _loaded = false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }
}
