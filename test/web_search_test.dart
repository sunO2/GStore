import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/websearch/tavily_client.dart';
import 'package:gstore/core/websearch/url_guard.dart';
import 'package:gstore/core/websearch/web_fetch_client.dart';
import 'package:gstore/core/websearch/web_search_config.dart';
import 'package:gstore/core/websearch/web_search_models.dart';
import 'package:gstore/core/websearch/web_search_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

WebSearchConfig _config({
  String apiKey = '',
  int dailySearchQuota = 50,
  int dailyFetchQuota = 30,
  bool enabled = true,
}) {
  return WebSearchConfig(
    enabled: enabled,
    apiKey: apiKey,
    dailySearchQuota: dailySearchQuota,
    dailyFetchQuota: dailyFetchQuota,
    maxResults: 5,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('TavilyClient keyless', () {
    test('keyless 请求头 + 结果解析', () async {
      late http.Request captured;
      final client = MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode({
            'query': 'termux',
            'results': [
              {
                'title': 'Termux | F-Droid',
                'url': 'https://f-droid.org/packages/com.termux/',
                'content': 'Terminal emulator with packages.',
                'score': 0.93,
                'published_date': '2026-10-01',
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      });
      final tavily = TavilyClient(config: _config(), client: client);

      final hits = await tavily.search('termux', count: 3, freshness: 'month');
      expect(captured.url.toString(), 'https://api.tavily.com/search');
      expect(captured.headers['X-Tavily-Access-Mode'], 'keyless');
      expect(captured.headers.containsKey('Authorization'), isFalse);
      final body = jsonDecode(captured.body) as Map<String, dynamic>;
      expect(body['query'], 'termux');
      expect(body['max_results'], 3);
      expect(body['days'], 30);
      expect(body['include_raw_content'], false);

      expect(hits, hasLength(1));
      expect(hits.first.title, 'Termux | F-Droid');
      expect(hits.first.url, 'https://f-droid.org/packages/com.termux/');
      expect(hits.first.snippet, contains('Terminal emulator'));
      expect(hits.first.publishedAt, '2026-10-01');
      expect(hits.first.score, closeTo(0.93, 0.0001));
    });

    test('keyed 模式带 Bearer，不带 keyless 头', () async {
      late http.Request captured;
      final client = MockClient((request) async {
        captured = request;
        return http.Response('{"results":[]}', 200);
      });
      final tavily = TavilyClient(
        config: _config(apiKey: 'tvly-test'),
        client: client,
      );
      await tavily.search('q');
      expect(captured.headers['Authorization'], 'Bearer tvly-test');
      expect(captured.headers.containsKey('X-Tavily-Access-Mode'), isFalse);
    });

    test('site 过滤拼进 query', () async {
      late http.Request captured;
      final client = MockClient((request) async {
        captured = request;
        return http.Response('{"results":[]}', 200);
      });
      final tavily = TavilyClient(config: _config(), client: client);
      await tavily.search('latest', site: 'github.com');
      final body = jsonDecode(captured.body) as Map<String, dynamic>;
      expect(body['query'], 'latest site:github.com');
    });

    test('daily_cap_reached → quota_exceeded，提示填 API Key', () async {
      final client = MockClient((request) async {
        return http.Response(
          jsonEncode({
            'error': {
              'code': 'daily_cap_reached',
              'message': 'You reached the daily keyless limit.',
            },
          }),
          432,
          headers: {'retry-after': '170'},
        );
      });
      final tavily = TavilyClient(config: _config(), client: client);
      await expectLater(
        tavily.search('x'),
        throwsA(isA<WebSearchException>()
            .having((e) => e.code, 'code', 'quota_exceeded')
            .having((e) => e.message, 'message', contains('API Key'))
            .having((e) => e.retryAfterSeconds, 'retryAfter', 170)),
      );
    });

    test('401 → unauthorized；坏 JSON → bad_response；空 query → bad_response', () async {
      final unauthorized = TavilyClient(
        config: _config(apiKey: 'bad'),
        client: MockClient((_) async => http.Response('{}', 401)),
      );
      await expectLater(
        unauthorized.search('x'),
        throwsA(isA<WebSearchException>()
            .having((e) => e.code, 'code', 'unauthorized')),
      );

      final broken = TavilyClient(
        config: _config(),
        client: MockClient((_) async => http.Response('<html>', 200)),
      );
      await expectLater(
        broken.search('x'),
        throwsA(isA<WebSearchException>()
            .having((e) => e.code, 'code', 'bad_response')),
      );

      final empty = TavilyClient(
        config: _config(),
        client: MockClient((_) async => http.Response('{}', 200)),
      );
      await expectLater(
        empty.search('  '),
        throwsA(isA<WebSearchException>()
            .having((e) => e.code, 'code', 'bad_response')),
      );
    });
  });

  group('WebSearchService', () {
    test('缓存命中不重复请求；配额用尽抛错', () async {
      var calls = 0;
      final service = WebSearchService(
        config: _config(dailySearchQuota: 2),
        searchClientFactory: (config) => TavilyClient(
          config: config,
          client: MockClient((request) async {
            calls++;
            return http.Response(
              jsonEncode({
                'results': [
                  {'title': 'A', 'url': 'https://a.example.com', 'content': 'hi'},
                ],
              }),
              200,
            );
          }),
        ),
      );

      final first = await service.search('same');
      expect(first, hasLength(1));
      final second = await service.search('same');
      expect(second, hasLength(1));
      expect(calls, 1, reason: '相同查询应命中缓存');

      // 另一个查询消耗掉最后一次配额后，再查就超限
      await service.search('other');
      await expectLater(
        service.search('third'),
        throwsA(isA<WebSearchException>()
            .having((e) => e.code, 'code', 'quota_exceeded')),
      );
    });

    test('关闭后两个工具都拒绝执行', () async {
      final service = WebSearchService(config: _config(enabled: false));
      await expectLater(
        service.search('x'),
        throwsA(isA<WebSearchException>()
            .having((e) => e.code, 'code', 'disabled')),
      );
      await expectLater(
        service.fetch('https://example.com'),
        throwsA(isA<WebSearchException>()
            .having((e) => e.code, 'code', 'disabled')),
      );
    });

    test('formatSearch 带来源、编号与注入防护提示', () async {
      final service = WebSearchService(config: _config());
      final config = await service.config();
      final text = service.formatSearch(
        'termux',
        const [
          WebSearchHit(
            title: 'Termux',
            url: 'https://f-droid.org/packages/com.termux/',
            snippet: 'Terminal emulator',
            publishedAt: '2026-10-01',
          ),
        ],
        config,
      );
      expect(text, contains('Tavily keyless'));
      expect(text, contains('指令'));
      expect(text, contains('1. Termux'));
      expect(text, contains('https://f-droid.org/packages/com.termux/'));
      expect(text, contains('发布：2026-10-01'));
    });
  });

  group('WebFetchClient', () {
    test('直连 HTML 抽取正文：去脚本/导航，保留文章', () async {
      final client = MockClient((request) async {
        expect(request.url.toString(), 'https://93.184.216.34/page');
        return http.Response(
          '''<!doctype html><html><head>
          <title>Blog</title>
          <meta property="og:title" content="How to install Termux">
          <meta property="article:published_time" content="2026-11-01">
          </head><body>
          <nav>导航菜单</nav>
          <article>
            <h1>安装 Termux</h1>
            <p>Termux 是一个终端模拟器，内置包管理器，可以在 Android 上运行
              常见的命令行工具。它不需要 root，但部分功能需要额外配置。</p>
            <p>先下载 APK，然后安装；首次启动会初始化包索引，之后可以用
              pkg install 安装需要的软件包。</p>
          </article>
          <footer>版权</footer>
          <script>alert('x')</script>
          </body></html>''',
          200,
          headers: {'content-type': 'text/html; charset=utf-8'},
        );
      });
      final fetcher = WebFetchClient(client: client);
      final page = await fetcher.fetch('https://93.184.216.34/page');
      expect(page.via, 'direct');
      expect(page.title, 'How to install Termux');
      expect(page.publishedAt, '2026-11-01');
      expect(page.content, contains('Termux 是一个终端模拟器'));
      expect(page.content, contains('先下载 APK'));
      expect(page.content, isNot(contains('导航菜单')));
      expect(page.content, isNot(contains('版权')));
      expect(page.content, isNot(contains('alert')));
    });

    test('直连 403 → Jina 兜底并去掉响应头', () async {
      final client = MockClient((request) async {
        if (request.url.host == 'r.jina.ai') {
          return http.Response(
            'Title: Release 1.2.3\n'
            'URL Source: https://93.184.216.34/release\n'
            'Markdown Content:\n'
            '# 1.2.3\n'
            '- 修复了安装失败的问题\n'
            '- 新增联网搜索\n',
            200,
            headers: {'content-type': 'text/plain; charset=utf-8'},
          );
        }
        return http.Response('forbidden', 403);
      });
      final fetcher = WebFetchClient(client: client);
      final page = await fetcher.fetch('https://93.184.216.34/release');
      expect(page.via, 'jina');
      expect(page.title, 'Release 1.2.3');
      expect(page.content, contains('修复了安装失败的问题'));
      expect(page.content, isNot(contains('Markdown Content:')));
    });

    test('内网地址与重定向到内网都被拒绝', () async {
      final fetcher = WebFetchClient(
        client: MockClient((_) async => http.Response('ok', 200)),
      );
      await expectLater(
        fetcher.fetch('http://192.168.1.10/'),
        throwsA(isA<WebSearchException>()
            .having((e) => e.code, 'code', 'blocked_url')),
      );
      await expectLater(
        fetcher.fetch('http://169.254.169.254/latest/meta-data/'),
        throwsA(isA<WebSearchException>()
            .having((e) => e.code, 'code', 'blocked_url')),
      );
      await expectLater(
        fetcher.fetch('file:///etc/passwd'),
        throwsA(isA<WebSearchException>()
            .having((e) => e.code, 'code', 'blocked_url')),
      );

      final redirector = WebFetchClient(
        client: MockClient((request) async {
          if (request.url.host == '93.184.216.34') {
            return http.Response('', 302,
                headers: {'location': 'http://10.0.0.1/secret'});
          }
          return http.Response('secret', 200);
        }),
      );
      await expectLater(
        redirector.fetch('https://93.184.216.34/'),
        throwsA(isA<WebSearchException>()
            .having((e) => e.code, 'code', 'blocked_url')),
      );
    });

    test('maxChars 截断', () async {
      final client = MockClient((request) async {
        return http.Response('a' * 500, 200,
            headers: {'content-type': 'text/plain'});
      });
      final fetcher = WebFetchClient(client: client);
      final page = await fetcher.fetch(
        'https://93.184.216.34/text',
        maxChars: 60,
      );
      expect(page.truncated, isTrue);
      expect(page.content, contains('截断'));
    });
  });

  group('UrlGuard', () {
    test('拒绝非 http(s) 与私网/保留地址', () async {
      for (final url in ['ftp://example.com', 'javascript:alert(1)']) {
        await expectLater(
          Future<void>.sync(() => UrlGuard.parseHttpUrl(url)),
          throwsA(isA<WebSearchException>()),
          reason: url,
        );
      }
      // 明确拒绝的必须抛
      for (final url in [
        'http://127.0.0.1/',
        'http://10.1.2.3/',
        'http://192.168.0.1/',
        'http://169.254.169.254/',
        'http://[::1]/',
        'http://[fc00::1]/',
      ]) {
        await expectLater(
          UrlGuard.assertPublicHost(UrlGuard.parseHttpUrl(url)),
          throwsA(isA<WebSearchException>()),
          reason: url,
        );
      }
      expect(
        UrlGuard.parseHttpUrl('https://93.184.216.34/x').host,
        '93.184.216.34',
      );
      await UrlGuard.assertPublicHost(
        UrlGuard.parseHttpUrl('https://93.184.216.34/x'),
      );
    });
  });
}
