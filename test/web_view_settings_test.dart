import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/webview/web_view_settings.dart';
import 'package:gstore/core/webview/webview_url_normalizer.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await WebViewSettingsStore.instance.debugReset();
  });

  group('WebViewSettings', () {
    test('默认值与搜索模板', () {
      const s = WebViewSettings.defaults;
      expect(s.searchEngine, WebSearchEngine.bing);
      expect(s.nightMode, isFalse);
      expect(s.desktopMode, isFalse);
      expect(s.textZoom, 100);
      expect(s.loadImages, isTrue);
      expect(s.searchTemplate, contains('%s'));
      expect(s.searchUrl('termux dev'),
          'https://www.bing.com/search?q=termux%20dev');
    });

    test('切换引擎后使用对应模板', () {
      const s = WebViewSettings(searchEngine: WebSearchEngine.baidu);
      expect(s.searchUrl('termux'), 'https://www.baidu.com/s?wd=termux');
    });

    test('自定义模板无效时回退必应', () {
      const invalid = WebViewSettings(
        searchEngine: WebSearchEngine.custom,
        customSearchTemplate: 'https://example.com/search',
      );
      expect(invalid.searchTemplate, contains('bing.com'));

      const valid = WebViewSettings(
        searchEngine: WebSearchEngine.custom,
        customSearchTemplate: 'https://example.com/s?q=%s&lang=zh',
      );
      expect(valid.searchUrl('a b'),
          'https://example.com/s?q=a%20b&lang=zh');
    });

    test('textZoom 限制在 70–200', () {
      const s = WebViewSettings();
      expect(s.copyWith(textZoom: 10).textZoom, 70);
      expect(s.copyWith(textZoom: 999).textZoom, 200);
    });

    test('JSON 往返', () {
      const s = WebViewSettings(
        searchEngine: WebSearchEngine.duckduckgo,
        desktopMode: true,
        nightMode: true,
        textZoom: 130,
        loadImages: false,
        javaScriptEnabled: false,
        cacheEnabled: false,
        thirdPartyCookies: false,
      );
      final back = WebViewSettings.fromJson(s.toJson());
      expect(back.searchEngine, WebSearchEngine.duckduckgo);
      expect(back.desktopMode, isTrue);
      expect(back.nightMode, isTrue);
      expect(back.textZoom, 130);
      expect(back.loadImages, isFalse);
      expect(back.javaScriptEnabled, isFalse);
      expect(back.cacheEnabled, isFalse);
      expect(back.thirdPartyCookies, isFalse);
    });
  });

  group('WebViewSettingsStore', () {
    test('保存后可重新加载', () async {
      final store = WebViewSettingsStore.instance;
      await store.load();
      expect(store.settings.nightMode, isFalse);

      await store.save(store.settings.copyWith(
        nightMode: true,
        searchEngine: WebSearchEngine.google,
      ));
      await store.load(force: true);
      expect(store.settings.nightMode, isTrue);
      expect(store.settings.searchEngine, WebSearchEngine.google);
    });

    test('恢复默认设置', () async {
      final store = WebViewSettingsStore.instance;
      await store.save(store.settings.copyWith(nightMode: true, textZoom: 150));
      await store.reset();
      expect(store.settings.nightMode, isFalse);
      expect(store.settings.textZoom, 100);
    });
  });

  group('resolveWebInput（自定义模板）', () {
    test('关键词使用传入的搜索模板', () {
      expect(
        resolveWebInput(
          'termux',
          searchTemplate: 'https://example.com/s?q=%s',
        ),
        'https://example.com/s?q=termux',
      );
    });

    test('网址仍直接打开', () {
      expect(
        resolveWebInput('termux.dev', searchTemplate: 'https://example.com/s?q=%s'),
        'https://termux.dev',
      );
    });
  });
}
