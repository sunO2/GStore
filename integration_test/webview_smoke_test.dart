import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/webview/webview_session_service.dart';
import 'package:gstore/core/webview/webview_url_policy.dart';
import 'package:integration_test/integration_test.dart';

/// On-device smoke test for the headless WebView tool.
///
/// Run on a device:
///   flutter test integration_test/webview_smoke_test.dart -d <deviceId>
///
/// A loopback HTTP server is used, so the URL policy is constructed with
/// `enforcePublicHosts: false` (production keeps the default).
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late HttpServer server;
  late String baseUrl;

  setUpAll(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    baseUrl = 'http://127.0.0.1:${server.port}';
    server.listen((request) async {
      final path = request.uri.path;
      if (path == '/') {
        const html = '''
<!doctype html>
<html><head><meta charset="utf-8"><title>WebView Test</title></head>
<body>
  <h1 id="title">Hello WebView</h1>
  <button id="btn"
    onclick="document.getElementById('out').textContent='clicked'">Click</button>
  <div id="out">idle</div>
  <script>
    fetch('/api/fetch?q=termux', {
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({q: 'termux'})
    });
    var xhr = new XMLHttpRequest();
    xhr.open('POST', '/api/xhr');
    xhr.setRequestHeader('Content-Type', 'application/json');
    xhr.send(JSON.stringify({a: 1}));
  </script>
</body></html>
''';
        request.response.headers.contentType =
            ContentType('text', 'html', charset: 'utf-8');
        request.response.write(html);
      } else if (path == '/api/fetch' || path == '/api/xhr') {
        final body = await utf8.decoder.bind(request).join();
        request.response.headers.contentType =
            ContentType('application', 'json', charset: 'utf-8');
        request.response.write(jsonEncode({
          'ok': true,
          'path': path,
          'received': body,
        }));
      } else {
        request.response.statusCode = HttpStatus.notFound;
        request.response.write('not found');
      }
      await request.response.close();
    });
  });

  tearDownAll(() async {
    await server.close(force: true);
  });

  testWidgets('headless WebView renders, captures XHR/fetch and clicks',
      (tester) async {
    final service = WebViewSessionService(
      urlPolicy: WebViewUrlPolicy(enforcePublicHosts: false),
    );
    addTearDown(service.close);

    await tester.runAsync(() async {
      final opened = await service.handle({
        'action': 'open',
        'url': baseUrl,
        'waitUntil': 'networkIdle',
        'settleMs': 800,
        'timeoutMs': 15000,
      });
      expect(opened, contains('已加载'), reason: opened);

      final content = await service.handle({
        'action': 'content',
        'format': 'text',
        'maxChars': 4000,
      });
      expect(content, contains('Hello WebView'), reason: content);

      final requests = await service.handle({
        'action': 'requests',
        'includeBodies': true,
        'limit': 20,
      });
      expect(requests, contains('/api/fetch'), reason: requests);
      expect(requests, contains('/api/xhr'), reason: requests);
      expect(requests, contains('termux'), reason: requests);
      expect(requests, contains('200'), reason: requests);

      final har = await service.handle({'action': 'har', 'limit': 20});
      expect(har, contains('"log"'), reason: har);
      expect(har, contains('/api/fetch'), reason: har);

      final title = await service.handle({
        'action': 'eval',
        'script': 'return document.title',
      });
      expect(title, contains('WebView Test'), reason: title);

      final scrolled = await service.handle({
        'action': 'scroll',
        'y': 100,
      });
      expect(scrolled, contains('已滚动'), reason: scrolled);

      final clicked = await service.handle({
        'action': 'click',
        'selector': '#btn',
        'waitMs': 300,
      });
      expect(clicked, contains('已点击'), reason: clicked);

      final out = await service.handle({
        'action': 'eval',
        'script': "return document.getElementById('out').textContent",
      });
      expect(out, contains('clicked'), reason: out);
    });
  });
}
