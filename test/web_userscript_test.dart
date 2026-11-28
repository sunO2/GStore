import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/webview/web_userscript.dart';
import 'package:gstore/core/webview/web_userscript_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String _sample = r'''
// ==UserScript==
// @name          Test Script
// @namespace     gstore.test
// @version       1.2.3
// @description   demo script
// @author        tester
// @match         https://*.example.com/*
// @exclude       https://admin.example.com/*
// @run-at        document-start
// @grant         GM_setValue
// @require       https://cdn.example.com/lib.js
// ==/UserScript==
console.log('hi');
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await WebUserScriptStore.instance.debugReset();
  });

  group('解析用户脚本', () {
    test('读取全部元数据', () {
      final parsed = parseWebUserScript(
        _sample,
        sourceUrl: 'https://greasyfork.org/scripts/1/x.user.js',
      );
      expect(parsed.ok, isTrue);
      final script = parsed.script!;
      expect(script.name, 'Test Script');
      expect(script.namespace, 'gstore.test');
      expect(script.version, '1.2.3');
      expect(script.description, 'demo script');
      expect(script.author, 'tester');
      expect(script.matches, ['https://*.example.com/*']);
      expect(script.excludes, ['https://admin.example.com/*']);
      expect(script.requires, ['https://cdn.example.com/lib.js']);
      expect(script.grants, ['GM_setValue']);
      expect(script.runAt, 'document-start');
      expect(script.key, 'gstore.test::Test Script');
      expect(script.sourceUrl, contains('x.user.js'));
    });

    test('没有元数据块时给出错误', () {
      final parsed = parseWebUserScript('console.log(1)');
      expect(parsed.ok, isFalse);
      expect(parsed.error, contains('UserScript'));
    });

    test('空内容被拒绝', () {
      expect(parseWebUserScript('   ').ok, isFalse);
    });

    test('缺少 @name 时用安装地址兜底', () {
      final parsed = parseWebUserScript(
        '// ==UserScript==\n// @match *://*/*\n// ==/UserScript==\n',
        sourceUrl: 'https://example.com/demo.user.js',
      );
      expect(parsed.script!.name, 'demo.user.js');
    });
  });

  group('匹配规则', () {
    test('@match 子域与协议', () {
      final script = parseWebUserScript(_sample).script!;
      expect(script.matchesUrl('https://example.com/a'), isTrue);
      expect(script.matchesUrl('https://m.example.com/a'), isTrue);
      expect(script.matchesUrl('http://example.com/a'), isFalse);
      expect(script.matchesUrl('https://admin.example.com/a'), isFalse);
      expect(script.matchesUrl('https://other.com/a'), isFalse);
    });

    test('通配符协议与路径', () {
      final script = parseWebUserScript(
        '// ==UserScript==\n// @name  T\n// @match *://*/foo/*\n// ==/UserScript==\n',
      ).script!;
      expect(script.matchesUrl('http://x.com/foo/bar'), isTrue);
      expect(script.matchesUrl('https://y.com/foo'), isFalse);
      expect(script.matchesUrl('https://y.com/bar/foo'), isFalse);
    });

    test('@include 支持正则与 glob', () {
      final script = parseWebUserScript(
        '// ==UserScript==\n// @name T\n'
        '// @include /^https:\\/\\/a\\.com\\/\\d+/\n'
        '// @include https://b.com/*/edit\n'
        '// ==/UserScript==\n',
      ).script!;
      expect(script.matchesUrl('https://a.com/123'), isTrue);
      expect(script.matchesUrl('https://a.com/x'), isFalse);
      expect(script.matchesUrl('https://b.com/doc/edit'), isTrue);
      expect(script.matchesUrl('https://b.com/doc/view'), isFalse);
    });

    test('origin 白名单在可推导时收窄', () {
      final script = parseWebUserScript(_sample).script!;
      expect(script.originRules, {'https://*.example.com'});
    });
  });

  group('注入引导脚本', () {
    test('包含 token、匹配判断与 GM 定义', () {
      final script = parseWebUserScript(_sample).script!;
      final source = buildUserScriptBootstrap(script, token: 'tok123');
      expect(source, contains('tok123'));
      expect(source, contains('new RegExp'));
      expect(source, contains('Test Script'));
      expect(source, contains('GM_setValue'));
      expect(source, contains("console.log('hi')"));
      expect(source, contains("callHandler('gstoreUserscript'"));
      // GM 只在闭包里，不挂到 window。
      expect(source.contains('window.GM_'), isFalse);
    });

    test('没有匹配规则时不生成脚本', () {
      final script = parseWebUserScript(
        '// ==UserScript==\n// @name T\n// ==/UserScript==\n',
      ).script!;
      expect(buildUserScriptBootstrap(script, token: 't'), isEmpty);
    });

    test('识别 .user.js 地址', () {
      expect(
        looksLikeUserScriptUrl(
          'https://update.greasyfork.org/scripts/1/x.user.js',
        ),
        isTrue,
      );
      expect(looksLikeUserScriptUrl('https://example.com/x.js'), isFalse);
      expect(looksLikeUserScriptUrl('ftp://example.com/x.user.js'), isFalse);
    });
  });

  group('存储', () {
    test('同 key 视为更新并保留启用状态与存储值', () async {
      final first = parseWebUserScript(_sample).script!;
      await WebUserScriptStore.instance.upsert(first);
      final saved = WebUserScriptStore.instance.scripts.single;
      await WebUserScriptStore.instance.setEnabled(saved.id, false);
      await WebUserScriptStore.instance.setValue(saved.id, 'count', 2);

      final updated = parseWebUserScript(
        _sample.replaceFirst('1.2.3', '1.3.0'),
      ).script!;
      final result = await WebUserScriptStore.instance.upsert(updated);

      expect(result.updated, isTrue);
      final merged = WebUserScriptStore.instance.scripts.single;
      expect(merged.version, '1.3.0');
      expect(merged.enabled, isFalse);
      expect(merged.values['count'], 2);
      expect(merged.id, saved.id);
    });

    test('按 URL 找出命中的脚本', () async {
      final script = parseWebUserScript(_sample).script!;
      await WebUserScriptStore.instance.upsert(script);
      expect(
        WebUserScriptStore.instance.scriptsForUrl('https://a.example.com/x'),
        hasLength(1),
      );
      expect(
        WebUserScriptStore.instance.scriptsForUrl('https://other.com'),
        isEmpty,
      );
    });

    test('持久化后能读回', () async {
      final script = parseWebUserScript(_sample).script!;
      await WebUserScriptStore.instance.upsert(script);
      await WebUserScriptStore.instance.load(force: true);
      expect(WebUserScriptStore.instance.scripts, hasLength(1));
      expect(WebUserScriptStore.instance.scripts.single.name, 'Test Script');
    });
  });
}
