import 'dart:convert';

import 'package:http/http.dart' as http;

/// 必应搜索建议。
///
/// 使用 `api.bing.com/qsonhs.aspx?type=cb&q=` —— 返回标准 JSON
/// （`AS.Results[].Suggests[].Txt`），不需要页面脚本或 JSONP。
/// 失败（网络/解析/超时）一律返回空列表，输入框继续可正常使用。
Future<List<String>> fetchBingSuggestions(
  String query, {
  http.Client? httpClient,
  Duration timeout = const Duration(seconds: 3),
  int limit = 8,
}) async {
  final text = query.trim();
  if (text.isEmpty) return const [];

  final client = httpClient ?? http.Client();
  final ownClient = httpClient == null;
  try {
    final uri = Uri.https('api.bing.com', '/qsonhs.aspx', {
      'type': 'cb',
      'q': text,
    });
    final response = await client.get(uri,
        headers: const {'Accept': 'application/json'}).timeout(timeout);
    if (response.statusCode != 200) return const [];
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is! Map) return const [];
    final asNode = decoded['AS'];
    final results = asNode is Map ? asNode['Results'] : null;
    if (results is! List) return const [];

    final out = <String>[];
    for (final result in results) {
      if (result is! Map) continue;
      final suggests = result['Suggests'];
      if (suggests is! List) continue;
      for (final item in suggests) {
        if (item is! Map) continue;
        final text = item['Txt']?.toString().trim() ?? '';
        if (text.isEmpty || out.contains(text)) continue;
        out.add(text);
        if (out.length >= limit) return out;
      }
    }
    return out;
  } catch (_) {
    return const [];
  } finally {
    if (ownClient) client.close();
  }
}
