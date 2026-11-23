/// Tavily 搜索客户端（P3-7）
///
/// 支持两种模式：
/// - **keyless**：`X-Tavily-Access-Mode: keyless`，无需账号，有每日/限速上限；
/// - **keyed**：`Authorization: Bearer tvly-…`，免费 1,000 credits/月。
///
/// 只依赖 `http`，方便单测注入 MockClient。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:http/http.dart' as http;

import 'web_search_config.dart';
import 'web_search_models.dart';

class TavilyClient {
  TavilyClient({
    required this.config,
    http.Client? client,
    this.timeout = const Duration(seconds: 20),
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null;

  final WebSearchConfig config;
  final Duration timeout;
  final http.Client _client;
  final bool _ownsClient;

  /// 搜索。
  ///
  /// [count] 上限 10；[freshness] 支持 `day|week|month|year`；
  /// [site] 为域名（逗号分隔多个），拼成 `site:` 前缀。
  Future<List<WebSearchHit>> search(
    String query, {
    int? count,
    String? freshness,
    String? site,
  }) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      throw WebSearchException('bad_response', '搜索关键词不能为空');
    }
    var q = trimmed;
    final siteFilter = site?.trim() ?? '';
    if (siteFilter.isNotEmpty) {
      final domains = siteFilter
          .split(',')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();
      if (domains.length == 1) {
        q = '$q site:${domains.first}';
      } else if (domains.isNotEmpty) {
        q = '$q (${domains.map((d) => 'site:$d').join(' OR ')})';
      }
    }

    final body = <String, dynamic>{
      'query': q,
      'max_results': (count ?? config.maxResults).clamp(1, 10),
      'search_depth': 'basic',
      'include_answer': false,
      'include_raw_content': false,
    };
    final days = _freshnessDays(freshness);
    if (days != null) body['days'] = days;

    final base = config.baseUrl.trim().isEmpty
        ? 'https://api.tavily.com'
        : config.baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    final uri = Uri.parse('$base/search');
    final headers = <String, String>{
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      // 部分网关按 UA 判别客户端；给一个可辨识的标识
      'User-Agent': 'GStore-Agent/1.0 (Android)',
    };
    if (config.isKeyless) {
      headers['X-Tavily-Access-Mode'] = 'keyless';
    } else {
      headers['Authorization'] = 'Bearer ${config.apiKey.trim()}';
    }

    http.Response response;
    try {
      response = await _client
          .post(uri, headers: headers, body: jsonEncode(body))
          .timeout(timeout);
    } on TimeoutException {
      throw WebSearchException('network', '联网搜索超时，请稍后重试');
    } catch (error) {
      throw WebSearchException('network', '联网搜索失败：$error');
    }

    if (response.statusCode != 200) {
      throw _errorFromResponse(response);
    }
    Map<String, dynamic> decoded;
    try {
      decoded = Map<String, dynamic>.from(
        jsonDecode(utf8.decode(response.bodyBytes)) as Map,
      );
    } catch (error) {
      throw WebSearchException('bad_response', '搜索返回格式异常：$error');
    }
    final rawResults = decoded['results'];
    if (rawResults is! List) {
      return const [];
    }
    final hits = <WebSearchHit>[];
    for (final item in rawResults) {
      if (item is! Map) continue;
      final map = Map<String, dynamic>.from(item);
      final url = (map['url'] ?? '').toString();
      if (url.isEmpty) continue;
      hits.add(
        WebSearchHit(
          title: (map['title'] ?? '').toString().trim().isEmpty
              ? url
              : map['title'].toString().trim(),
          url: url,
          snippet: (map['content'] ?? '').toString().trim(),
          content: map['raw_content'] is String &&
                  (map['raw_content'] as String).trim().isNotEmpty
              ? (map['raw_content'] as String).trim()
              : null,
          publishedAt: map['published_date']?.toString(),
          score: map['score'] is num
              ? (map['score'] as num).toDouble()
              : double.tryParse(map['score']?.toString() ?? ''),
        ),
      );
    }
    return hits;
  }

  /// 把错误响应翻译成可操作的异常（模型可以把提示转述给用户）。
  WebSearchException _errorFromResponse(http.Response response) {
    final retryAfter = int.tryParse(response.headers['retry-after'] ?? '');
    String code = 'http_${response.statusCode}';
    String message = '联网搜索失败（HTTP ${response.statusCode}）';
    try {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is Map) {
        final error = decoded['error'];
        if (error is Map) {
          code = (error['code'] ?? code).toString();
          message = (error['message'] ?? message).toString();
        } else if (error is String) {
          message = error;
        }
      }
    } catch (e) {
      // 非 JSON 错误体：保留状态码文案
      debugPrint('TavilyClient: 解析错误体失败 - $e');
    }
    if (response.statusCode == 429 || code == 'daily_cap_reached') {
      return WebSearchException(
        'quota_exceeded',
        '$message（可稍后重试，或在联网检索设置里填入 Tavily API Key 提升额度）',
        retryAfterSeconds: retryAfter,
      );
    }
    if (response.statusCode == 401 || response.statusCode == 403) {
      return WebSearchException(
        'unauthorized',
        'Tavily 鉴权失败：请检查 API Key，或清空 Key 用 keyless 模式',
      );
    }
    return WebSearchException(code, message);
  }

  static int? _freshnessDays(String? freshness) {
    switch ((freshness ?? '').trim().toLowerCase()) {
      case 'day':
      case 'd':
        return 1;
      case 'week':
      case 'w':
        return 7;
      case 'month':
      case 'm':
        return 30;
      case 'year':
      case 'y':
        return 365;
      default:
        return null;
    }
  }

  void dispose() {
    if (_ownsClient) _client.close();
  }
}
