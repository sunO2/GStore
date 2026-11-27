import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/webview/webview_url_normalizer.dart';
import 'package:gstore/page/web/view.dart';

void main() {
  group('normalizeWebViewUrl', () {
    test('保留完整的 http/https 地址', () {
      expect(normalizeWebViewUrl('https://github.com/termux'),
          'https://github.com/termux');
      expect(normalizeWebViewUrl('http://example.com/a?b=1'),
          'http://example.com/a?b=1');
    });

    test('裸域名补 https://', () {
      expect(normalizeWebViewUrl('example.com'), 'https://example.com');
      expect(normalizeWebViewUrl('  github.com/a/b  '),
          'https://github.com/a/b');
    });

    test('协议相对地址补 https', () {
      expect(normalizeWebViewUrl('//example.com/x'), 'https://example.com/x');
    });

    test('不可在内置浏览器打开的链接返回 null', () {
      for (final raw in [
        '',
        '   ',
        '#section',
        'mailto:a@b.com',
        'tel:10086',
        'intent://scan/#Intent;scheme=zxing;end',
        'javascript:alert(1)',
        'file:///sdcard/a.html',
        'data:text/html,<b>x</b>',
      ]) {
        expect(normalizeWebViewUrl(raw), isNull, reason: raw);
      }
    });
  });

  group('WebPage', () {
    testWidgets('非法链接显示提示而不是白屏', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: WebPage(url: 'mailto:a@b.com')),
      );
      await tester.pumpAndSettle();

      expect(find.text('这个链接不能在内置浏览器打开'), findsOneWidget);
      expect(find.text('mailto:a@b.com'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
