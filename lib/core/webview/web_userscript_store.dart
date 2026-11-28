import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gstore/http/rhttp_adapter.dart';
import 'package:gstore/core/webview/web_userscript.dart';

/// 用户脚本的持久化（SharedPreferences）。
///
/// 脚本体量通常几十 KB，和浏览器书签/历史放在一起足够；超过 1MB 的脚本在
/// 解析阶段就会被拒绝。
class WebUserScriptStore {
  WebUserScriptStore._();

  static final WebUserScriptStore instance = WebUserScriptStore._();

  static const String _key = 'web_userscripts_v1';

  final List<WebUserScript> _scripts = <WebUserScript>[];
  bool _loaded = false;

  List<WebUserScript> get scripts => List.unmodifiable(_scripts);
  bool get isLoaded => _loaded;

  List<WebUserScript> get enabledScripts =>
      [for (final script in _scripts) if (script.enabled) script];

  /// 当前 URL 命中的脚本（含已停用的，用于「本页使用的脚本」面板）。
  List<WebUserScript> scriptsForUrl(String? url) {
    if (url == null || url.isEmpty) return const [];
    return [
      for (final script in _scripts)
        if (script.matchesUrl(url)) script,
    ];
  }

  Future<void> load({bool force = false}) async {
    if (_loaded && !force) return;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    _scripts
      ..clear()
      ..addAll(_decode(raw));
    _loaded = true;
  }

  /// 安装 / 更新。同 `namespace + name` 视为更新：保留 id、启用状态和
  /// GM 存储值。
  Future<({WebUserScript script, bool updated})> upsert(
    WebUserScript incoming,
  ) async {
    final index = _scripts.indexWhere((item) => item.key == incoming.key);
    if (index < 0) {
      _scripts.add(incoming);
      await _persist();
      return (script: incoming, updated: false);
    }
    final old = _scripts[index];
    final merged = incoming.copyWith(
      id: old.id,
      enabled: old.enabled,
      values: old.values,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    _scripts[index] = merged;
    await _persist();
    return (script: merged, updated: true);
  }

  Future<void> setEnabled(String id, bool enabled) async {
    final index = _scripts.indexWhere((script) => script.id == id);
    if (index < 0) return;
    _scripts[index] = _scripts[index].copyWith(enabled: enabled);
    await _persist();
  }

  Future<void> remove(String id) async {
    _scripts.removeWhere((script) => script.id == id);
    await _persist();
  }

  Future<void> setValue(String scriptId, String key, Object? value) async {
    final index = _scripts.indexWhere((script) => script.id == scriptId);
    if (index < 0) return;
    final script = _scripts[index];
    final values = Map<String, Object?>.from(script.values)..[key] = value;
    _scripts[index] = script.copyWith(values: values);
    await _persist();
  }

  Future<void> deleteValue(String scriptId, String key) async {
    final index = _scripts.indexWhere((script) => script.id == scriptId);
    if (index < 0) return;
    final script = _scripts[index];
    if (!script.values.containsKey(key)) return;
    final values = Map<String, Object?>.from(script.values)..remove(key);
    _scripts[index] = script.copyWith(values: values);
    await _persist();
  }

  @visibleForTesting
  Future<void> debugReset() async {
    _scripts.clear();
    _loaded = false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key,
      jsonEncode([for (final script in _scripts) script.toJson()]),
    );
  }

  List<WebUserScript> _decode(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return [
        for (final item in decoded)
          if (item is Map)
            WebUserScript.fromJson(
              item.map((key, value) => MapEntry(key.toString(), value)),
            ),
      ];
    } catch (error) {
      debugPrint('WebUserScriptStore: 解析失败 - $error');
      return const [];
    }
  }
}

/// 下载 `.user.js` 与 `@require` 依赖。
class WebUserScriptFetcher {
  WebUserScriptFetcher._();

  static Dio? _client;

  static const String _userAgent =
      'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36 GStore/1.0';

  static Dio get _dio {
    final cached = _client;
    if (cached != null) return cached;
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 20),
        receiveTimeout: const Duration(seconds: 30),
        responseType: ResponseType.plain,
        followRedirects: true,
        maxRedirects: 5,
        validateStatus: (_) => true,
        headers: const {'User-Agent': _userAgent, 'Accept': '*/*'},
      ),
    );
    // 脚本来自任意站点，不复用「允许坏证书」的下载栈。
    dio.httpClientAdapter = RhttpAdapter(allowBadCertificate: false);
    _client = dio;
    return dio;
  }

  /// 抓取脚本原文。失败抛异常（由 UI 层转成提示）。
  static Future<String> fetchText(String url) async {
    final response = await _dio.get<String>(url);
    final status = response.statusCode ?? 0;
    if (status < 200 || status >= 300) {
      throw StateError('HTTP $status');
    }
    final text = response.data ?? '';
    if (text.isEmpty) throw StateError('响应为空');
    if (text.length > kWebUserScriptMaxBytes) {
      throw StateError('脚本太大（超过 1MB）');
    }
    return text;
  }

  /// `GM_xmlhttpRequest` 的底层请求（携带调用方给的 Cookie / 头）。
  static Future<
      ({
        int status,
        String statusText,
        String body,
        Map<String, String> headers,
        String url,
      })> request({
    required String method,
    required String url,
    Map<String, String>? headers,
    String? data,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final response = await _dio.request<String>(
      url,
      data: data,
      options: Options(
        method: method.toUpperCase(),
        headers: headers,
        receiveTimeout: timeout,
        sendTimeout: timeout,
        responseType: ResponseType.plain,
      ),
    );
    return (
      status: response.statusCode ?? 0,
      statusText: response.statusMessage ?? '',
      body: response.data ?? '',
      headers: {
        for (final entry in response.headers.map.entries)
          if (entry.value.isNotEmpty) entry.key: entry.value.join(', '),
      },
      url: response.realUri.toString(),
    );
  }

  /// 抓取并解析，顺带把 `@require` 抓下来拼进 prelude。
  static Future<WebUserScriptParseResult> fetch(String url) async {
    final text = await fetchText(url);
    final parsed = parseWebUserScript(text, sourceUrl: url);
    final script = parsed.script;
    if (script == null) return parsed;
    if (script.requires.isEmpty) return parsed;

    final buffer = StringBuffer();
    for (final require in script.requires) {
      final target = Uri.tryParse(require);
      if (target == null ||
          (target.scheme != 'http' && target.scheme != 'https')) {
        continue;
      }
      try {
        final code = await fetchText(require);
        buffer
          ..writeln('/* @require $require */')
          ..writeln(code)
          ..writeln(';');
      } catch (error) {
        debugPrint('WebUserScriptFetcher: @require 失败 $require - $error');
      }
    }
    return WebUserScriptParseResult(
      script: script.copyWith(prelude: buffer.toString()),
    );
  }
}
