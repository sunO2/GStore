/// 联网检索配置（P3-7）
///
/// 默认走 Tavily **keyless**（无需账号，限速）；填了 API Key 自动切到 keyed
/// 模式（Tavily 免费 1,000 credits/月）。配置存 SharedPreferences，刻意不放进
/// 配置中心：key 属于本机诊断偏好，不需要跨设备同步。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:shared_preferences/shared_preferences.dart';

class WebSearchConfig {
  WebSearchConfig({
    this.enabled = true,
    this.provider = 'tavily',
    this.apiKey = '',
    this.baseUrl = 'https://api.tavily.com',
    this.maxResults = 5,
    this.dailySearchQuota = 50,
    this.dailyFetchQuota = 30,
    this.jinaApiKey = '',
  });

  /// 总开关（关闭后两个工具都不再下发）
  bool enabled;

  /// `tavily` | `none`
  String provider;

  /// 空 = keyless 模式
  String apiKey;

  /// Tavily API 根地址（自建代理可改）
  String baseUrl;

  int maxResults;
  int dailySearchQuota;
  int dailyFetchQuota;

  /// 可选：Jina Reader key（不填也能用 `r.jina.ai`，20 RPM）
  String jinaApiKey;

  bool get isKeyless => apiKey.trim().isEmpty;

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'provider': provider,
        'apiKey': apiKey,
        'baseUrl': baseUrl,
        'maxResults': maxResults,
        'dailySearchQuota': dailySearchQuota,
        'dailyFetchQuota': dailyFetchQuota,
        'jinaApiKey': jinaApiKey,
      };

  factory WebSearchConfig.fromJson(Map<String, dynamic> json) {
    int asInt(Object? v, int fallback) => v is num ? v.toInt() : fallback;
    return WebSearchConfig(
      enabled: json['enabled'] as bool? ?? true,
      provider: json['provider'] as String? ?? 'tavily',
      apiKey: json['apiKey'] as String? ?? '',
      baseUrl: json['baseUrl'] as String? ?? 'https://api.tavily.com',
      maxResults: asInt(json['maxResults'], 5),
      dailySearchQuota: asInt(json['dailySearchQuota'], 50),
      dailyFetchQuota: asInt(json['dailyFetchQuota'], 30),
      jinaApiKey: json['jinaApiKey'] as String? ?? '',
    );
  }

  WebSearchConfig copyWith({
    bool? enabled,
    String? provider,
    String? apiKey,
    String? baseUrl,
    int? maxResults,
    int? dailySearchQuota,
    int? dailyFetchQuota,
    String? jinaApiKey,
  }) {
    return WebSearchConfig(
      enabled: enabled ?? this.enabled,
      provider: provider ?? this.provider,
      apiKey: apiKey ?? this.apiKey,
      baseUrl: baseUrl ?? this.baseUrl,
      maxResults: maxResults ?? this.maxResults,
      dailySearchQuota: dailySearchQuota ?? this.dailySearchQuota,
      dailyFetchQuota: dailyFetchQuota ?? this.dailyFetchQuota,
      jinaApiKey: jinaApiKey ?? this.jinaApiKey,
    );
  }

  static const String _key = 'agent_websearch_v1';

  static Future<WebSearchConfig> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return WebSearchConfig();
    try {
      return WebSearchConfig.fromJson(
        Map<String, dynamic>.from(jsonDecode(raw) as Map),
      );
    } catch (error) {
      debugPrint('WebSearchConfig: 解析配置失败，使用默认值 - $error');
      return WebSearchConfig();
    }
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(toJson()));
  }
}
