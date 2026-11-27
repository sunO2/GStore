import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 一条浏览记录 / 书签。
class WebPageEntry {
  const WebPageEntry({
    required this.url,
    required this.title,
    required this.time,
  });

  final String url;
  final String title;
  final int time;

  String get host {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) return url;
    return uri.host;
  }

  Map<String, Object?> toJson() => {
        'url': url,
        'title': title,
        'time': time,
      };

  factory WebPageEntry.fromJson(Map<String, Object?> json) => WebPageEntry(
        url: json['url']?.toString() ?? '',
        title: json['title']?.toString() ?? '',
        time: (json['time'] as num?)?.toInt() ??
            DateTime.now().millisecondsSinceEpoch,
      );
}

/// 内置浏览器的本地数据：历史记录与书签。
///
/// 只存 http(s) 地址，按 URL 去重（重复访问只更新时间并挪到最前），
/// 历史最多保留 [maxHistory] 条。
class WebBrowserStore {
  WebBrowserStore._();

  static final WebBrowserStore instance = WebBrowserStore._();

  static const String _historyKey = 'web_browser_history_v1';
  static const String _bookmarksKey = 'web_browser_bookmarks_v1';
  static const int maxHistory = 200;

  final List<WebPageEntry> _history = <WebPageEntry>[];
  final List<WebPageEntry> _bookmarks = <WebPageEntry>[];
  bool _loaded = false;

  List<WebPageEntry> get history => List.unmodifiable(_history);
  List<WebPageEntry> get bookmarks => List.unmodifiable(_bookmarks);
  bool get isLoaded => _loaded;

  Future<void> load({bool force = false}) async {
    if (_loaded && !force) return;
    final prefs = await SharedPreferences.getInstance();
    _history
      ..clear()
      ..addAll(_decode(prefs.getString(_historyKey)));
    _bookmarks
      ..clear()
      ..addAll(_decode(prefs.getString(_bookmarksKey)));
    _loaded = true;
  }

  /// 记录一次访问。非 http(s) 地址直接忽略。
  Future<void> recordVisit(String url, String title) async {
    final normalized = _normalize(url);
    if (normalized == null) return;
    _history.removeWhere((e) => e.url == normalized);
    _history.insert(
      0,
      WebPageEntry(
        url: normalized,
        title: _cleanTitle(title, normalized),
        time: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    if (_history.length > maxHistory) {
      _history.removeRange(maxHistory, _history.length);
    }
    await _persist(_historyKey, _history);
  }

  bool isBookmarked(String url) {
    final normalized = _normalize(url);
    if (normalized == null) return false;
    return _bookmarks.any((e) => e.url == normalized);
  }

  /// 切换收藏状态，返回切换后是否已收藏。
  Future<bool> toggleBookmark(String url, String title) async {
    final normalized = _normalize(url);
    if (normalized == null) return false;
    final index = _bookmarks.indexWhere((e) => e.url == normalized);
    if (index >= 0) {
      _bookmarks.removeAt(index);
      await _persist(_bookmarksKey, _bookmarks);
      return false;
    }
    _bookmarks.insert(
      0,
      WebPageEntry(
        url: normalized,
        title: _cleanTitle(title, normalized),
        time: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    await _persist(_bookmarksKey, _bookmarks);
    return true;
  }

  Future<void> removeHistory(String url) async {
    _history.removeWhere((e) => e.url == url);
    await _persist(_historyKey, _history);
  }

  Future<void> clearHistory() async {
    _history.clear();
    await _persist(_historyKey, _history);
  }

  Future<void> removeBookmark(String url) async {
    _bookmarks.removeWhere((e) => e.url == url);
    await _persist(_bookmarksKey, _bookmarks);
  }

  /// 测试用：重置内存与持久化。
  @visibleForTesting
  Future<void> debugReset() async {
    _history.clear();
    _bookmarks.clear();
    _loaded = false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_historyKey);
    await prefs.remove(_bookmarksKey);
  }

  Future<void> _persist(String key, List<WebPageEntry> entries) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      key,
      jsonEncode([for (final e in entries) e.toJson()]),
    );
  }

  List<WebPageEntry> _decode(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return [
        for (final item in decoded)
          if (item is Map)
            WebPageEntry.fromJson(
              item.map((key, value) => MapEntry(key.toString(), value)),
            ),
      ];
    } catch (_) {
      return const [];
    }
  }

  String? _normalize(String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || uri.host.isEmpty) return null;
    if (uri.scheme != 'http' && uri.scheme != 'https') return null;
    return uri.toString();
  }

  String _cleanTitle(String title, String url) {
    final text = title.trim();
    if (text.isNotEmpty) return text;
    return Uri.tryParse(url)?.host ?? url;
  }
}
