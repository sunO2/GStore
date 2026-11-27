import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/webview/web_browser_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await WebBrowserStore.instance.debugReset();
  });

  group('WebBrowserStore', () {
    test('记录访问：按 URL 去重并置顶', () async {
      final store = WebBrowserStore.instance;
      await store.recordVisit('https://a.com/1', 'A1');
      await store.recordVisit('https://b.com/2', 'B2');
      await store.recordVisit('https://a.com/1', 'A1 新标题');

      expect(store.history, hasLength(2));
      expect(store.history.first.url, 'https://a.com/1');
      expect(store.history.first.title, 'A1 新标题');
    });

    test('记录访问：忽略非 http(s) 与空标题回退域名', () async {
      final store = WebBrowserStore.instance;
      await store.recordVisit('mailto:a@b.com', 'mail');
      await store.recordVisit('https://c.com/x', '');
      expect(store.history, hasLength(1));
      expect(store.history.single.title, 'c.com');
    });

    test('历史最多保留 maxHistory 条', () async {
      final store = WebBrowserStore.instance;
      for (var i = 0; i < WebBrowserStore.maxHistory + 5; i++) {
        await store.recordVisit('https://site$i.com', 'S$i');
      }
      expect(store.history, hasLength(WebBrowserStore.maxHistory));
      expect(store.history.first.url, 'https://site${WebBrowserStore.maxHistory + 4}.com');
    });

    test('收藏可切换、可单独删除', () async {
      final store = WebBrowserStore.instance;
      expect(store.isBookmarked('https://a.com'), isFalse);
      expect(await store.toggleBookmark('https://a.com', 'A'), isTrue);
      expect(store.isBookmarked('https://a.com'), isTrue);
      expect(store.bookmarks, hasLength(1));

      expect(await store.toggleBookmark('https://a.com', 'A'), isFalse);
      expect(store.isBookmarked('https://a.com'), isFalse);

      await store.toggleBookmark('https://b.com', 'B');
      await store.removeBookmark('https://b.com');
      expect(store.bookmarks, isEmpty);
    });

    test('清空历史不影响书签', () async {
      final store = WebBrowserStore.instance;
      await store.recordVisit('https://a.com', 'A');
      await store.toggleBookmark('https://a.com', 'A');
      await store.clearHistory();
      expect(store.history, isEmpty);
      expect(store.bookmarks, hasLength(1));
    });

    test('持久化后可重新加载', () async {
      final store = WebBrowserStore.instance;
      await store.recordVisit('https://a.com', 'A');
      await store.toggleBookmark('https://a.com', 'A');

      await store.load(force: true);
      expect(store.history, hasLength(1));
      expect(store.bookmarks, hasLength(1));
    });
  });
}
