import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/design/app_code_view.dart';
import 'package:gstore/core/webview/web_browser_store.dart';
import 'package:gstore/core/webview/web_view_settings.dart';
import 'package:gstore/core/webview/webview_url_normalizer.dart';
import 'package:gstore/page/web/view.dart';
import 'package:gstore/page/web/web_sheets.dart';
import 'package:gstore/page/web/web_tools_sheets.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await WebViewSettingsStore.instance.debugReset();
  });

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

  group('resolveWebInput', () {
    test('网址直接打开', () {
      expect(resolveWebInput('termux.dev'), 'https://termux.dev');
      expect(resolveWebInput('https://termux.dev/wiki'),
          'https://termux.dev/wiki');
      expect(resolveWebInput('www.foo.com/a'), 'https://www.foo.com/a');
    });

    test('其它输入走搜索引擎', () {
      expect(resolveWebInput('termux'), webSearchUrl('termux'));
      expect(resolveWebInput('怎么安装 termux'), webSearchUrl('怎么安装 termux'));
      expect(resolveWebInput('1.5'), webSearchUrl('1.5'));
      expect(resolveWebInput('   '), isNull);
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

  group('更多菜单', () {
    testWidgets('宫格展示功能并返回选中动作', (tester) async {
      WebMoreAction? action;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (ctx) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () async {
                    action = await showWebMoreSheet(
                      ctx,
                      hasUrl: true,
                      nightMode: false,
                    );
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // 第 1 页：5 列 × 2 行。
      for (final label in [
        '书签',
        '历史',
        '下载',
        '页内查找',
        '夜间模式',
        '电脑模式',
        '字体大小',
        '查看源码',
        '页面信息',
        '资源嗅探',
      ]) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      // 设置固定在标题栏，不占用宫格。
      expect(find.text('设置'), findsNothing);
      expect(find.byTooltip('浏览器设置'), findsOneWidget);

      await tester.tap(find.text('页内查找'));
      await tester.pumpAndSettle();
      expect(action, WebMoreAction.findInPage);
    });

    testWidgets('标题栏设置按钮返回设置动作', (tester) async {
      WebMoreAction? action;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (ctx) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  action = await showWebMoreSheet(
                    ctx,
                    hasUrl: true,
                    nightMode: false,
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('浏览器设置'));
      await tester.pumpAndSettle();
      expect(action, WebMoreAction.settings);
    });

    testWidgets('没有页面时禁用依赖页面的工具', (tester) async {
      WebMoreAction? action;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (ctx) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  action = await showWebMoreSheet(
                    ctx,
                    hasUrl: false,
                    nightMode: false,
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('页内查找'), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(action, isNull);
    });
  });

  group('页面源码 / HTTP 认证', () {
    testWidgets('源码使用 AppCodeView 只读视图', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (ctx) => Scaffold(
              body: TextButton(
                onPressed: () => showWebSourceSheet(
                  ctx,
                  html: '<html><body><h1>hi</h1></body></html>',
                  url: 'https://example.com',
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.byType(AppCodeView), findsOneWidget);
      expect(find.text('页面源码'), findsOneWidget);
    });

    testWidgets('HTTP 认证弹层返回账号密码', (tester) async {
      ({String username, String password})? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (ctx) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  result = await showWebHttpAuthSheet(
                    ctx,
                    host: 'example.com',
                    realm: 'Restricted',
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('需要登录'), findsOneWidget);
      expect(find.text('example.com · Restricted'), findsOneWidget);

      await tester.enterText(find.byType(TextField).at(0), 'alice');
      await tester.enterText(find.byType(TextField).at(1), 'secret');
      await tester.tap(find.text('登录'));
      await tester.pumpAndSettle();

      expect(result?.username, 'alice');
      expect(result?.password, 'secret');
    });
  });

  group('历史/书签列表', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await WebBrowserStore.instance.debugReset();
      await WebBrowserStore.instance.recordVisit('https://a.com', '站点 A');
    });

    testWidgets('历史列表展示条目并返回选择', (tester) async {
      WebPageEntry? picked;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (ctx) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  picked = await showWebEntriesSheet(ctx, bookmarks: false);
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('站点 A'), findsOneWidget);
      await tester.tap(find.text('站点 A'));
      await tester.pumpAndSettle();
      expect(picked?.url, 'https://a.com');
    });
  });
}
