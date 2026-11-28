import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/webview/web_home.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await WebHomeStore.instance.debugReset();
  });

  group('WebHomeConfig', () {
    test('默认是内置主页', () {
      const config = WebHomeConfig.defaults;
      expect(config.mode, WebHomeMode.builtin);
      expect(config.isUsable, isTrue);
      expect(config.entryUrl, isNull);
    });

    test('在线主题只接受 http(s)', () {
      const ok = WebHomeConfig(
        mode: WebHomeMode.online,
        location: 'https://example.com/home.html',
      );
      expect(ok.isUsable, isTrue);
      expect(ok.entryUrl, 'https://example.com/home.html');

      for (final bad in ['', 'example.com', 'file:///tmp/a.html', 'mailto:a@b']) {
        final config =
            WebHomeConfig(mode: WebHomeMode.online, location: bad);
        expect(config.isUsable, isFalse, reason: bad);
        expect(config.entryUrl, isNull, reason: bad);
      }
    });

    test('本地 HTML 必须真实存在', () async {
      final directory =
          await Directory.systemTemp.createTemp('gstore-home-test');
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/home.html')
        ..writeAsStringSync('<html></html>');

      final config = WebHomeConfig(
        mode: WebHomeMode.local,
        location: file.path,
      );
      expect(config.isUsable, isTrue);
      expect(config.entryUrl, startsWith('file://'));

      final missing = WebHomeConfig(
        mode: WebHomeMode.local,
        location: '${directory.path}/missing.html',
      );
      expect(missing.isUsable, isFalse);
      expect(missing.entryUrl, isNull);
    });

    test('JSON 往返保留模式与地址', () {
      const config = WebHomeConfig(
        mode: WebHomeMode.online,
        location: 'https://example.com/home.html',
      );
      final restored = WebHomeConfig.fromJson(config.toJson());
      expect(restored.mode, WebHomeMode.online);
      expect(restored.location, 'https://example.com/home.html');
    });

    test('未知模式回退到内置主页', () {
      final restored = WebHomeConfig.fromJson({'mode': 'wat'});
      expect(restored.mode, WebHomeMode.builtin);
    });
  });

  group('WebHomeStore', () {
    test('保存后能重新读取', () async {
      await WebHomeStore.instance.save(
        const WebHomeConfig(
          mode: WebHomeMode.online,
          location: 'https://example.com/home.html',
        ),
      );
      await WebHomeStore.instance.load(force: true);
      final config = WebHomeStore.instance.config;
      expect(config.mode, WebHomeMode.online);
      expect(config.location, 'https://example.com/home.html');

      await WebHomeStore.instance.reset();
      await WebHomeStore.instance.load(force: true);
      expect(WebHomeStore.instance.config.mode, WebHomeMode.builtin);
    });
  });

  group('内置主页文档', () {
    test('识别主页伪 origin', () {
      expect(isWebHomeUrl(kWebHomeOrigin), isTrue);
      expect(isWebHomeUrl('$kWebHomeOrigin/'), isTrue);
      expect(isWebHomeUrl('$kWebHomeOrigin/home.html'), isTrue);
      expect(isWebHomeUrl('https://example.com'), isFalse);
      expect(isWebHomeUrl(null), isFalse);
      expect(isWebHomeUrl(''), isFalse);
    });

    test('注入主题变量、深色标记与占位文案', () async {
      final template = await primeWebHomeTemplate();
      expect(template, isNotEmpty);
      expect(template, contains('__GS_THEME__'));

      final html = buildWebHomeHtml(
        css: const {'--bg': '#101010', '--fg': '#ffffff'},
        dark: true,
        placeholder: '搜索或输入网址',
      );
      expect(html, contains('--bg:#101010'));
      expect(html, contains('--fg:#ffffff'));
      expect(html, contains('data-theme="dark"'));
      expect(html, isNot(contains('__GS_THEME__')));
      expect(html, contains('gstoreHome'));
    });
  });
}
