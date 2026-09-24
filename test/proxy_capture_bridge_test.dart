// Todo 24 tests：抓包详情动作桥接（复制 cURL / 保存到请求调试 / 创建改写规则）。
//
// 密闭式：注入假 [ProxyCaptureDetailFacade]（不触碰 FFI）与假 [CaptureBridge]
// （不触碰请求调试 store / 页面）。弹层宿主复用生产全局通道
// `appNavigatorKey` + `AppDialogs.scaffoldMessengerKey`，动作菜单走真实
// `AppSheet` 呈现路径。
//
// 覆盖（Todo 24 验收）：
// * 纯函数：cURL 最小拼装（method/url/headers/body 等价）+ 单引号转义 + URL 回退；
// * 纯函数：改写规则预填（method/url + 当前响应作为 replace 初值）；
// * 三动作分别调用对应注入接口 / 写剪贴板，且携带正确载荷；
// * Body「作为改写响应」接缝；
// * store 写失败 / 建规则失败 / 未接线桥 → `showError` 不崩。

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/navigation/nav_key.dart';
import 'package:gstore/core/rust/proxy/ProxyContract.dart';
import 'package:gstore/page/proxy/proxy_capture_bridge.dart';
import 'package:gstore/page/proxy/proxy_capture_detail_page.dart';

// ==================== 测试宿主 ====================

Widget _host(Widget child) => MaterialApp(
      navigatorKey: appNavigatorKey,
      scaffoldMessengerKey: AppDialogs.scaffoldMessengerKey,
      home: child,
    );

Future<void> _settleLoad(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
  await tester.pump();
}

// ==================== 假实现 ====================

class _FakeDetailFacade implements ProxyCaptureDetailFacade {
  _FakeDetailFacade(this.value);

  CaptureDetail value;

  @override
  Future<CaptureDetail> detail(int recordId) async => value;
}

class _FakeBridge implements CaptureBridge {
  int saveCalls = 0;
  int ruleCalls = 0;
  CaptureDetail? savedDetail;
  CaptureRulePrefill? rulePrefill;

  bool failSave = false;
  bool failRule = false;

  @override
  Future<void> saveToCollection(CaptureDetail detail) async {
    saveCalls++;
    if (failSave) throw Exception('写库失败');
    savedDetail = detail;
  }

  @override
  Future<void> openRewriteRuleEditor(CaptureRulePrefill prefill) async {
    ruleCalls++;
    if (failRule) throw Exception('建规则失败');
    rulePrefill = prefill;
  }
}

// ==================== 样例数据 ====================

CaptureDetail _detail({
  int recordId = 7,
  String host = 'example.com',
  String method = 'POST',
  String scheme = 'https',
  String url = 'https://example.com/api/login',
  int statusCode = 200,
  String reqHeaders = 'Content-Type: application/json\r\nX-Token: abc',
  String respHeaders = 'Content-Type: application/json',
  List<int> reqBody = const <int>[],
  List<int> respBody = const <int>[],
}) {
  return CaptureDetail(
    recordId: recordId,
    host: host,
    method: method,
    scheme: scheme,
    url: url,
    statusCode: statusCode,
    reqHeaders: reqHeaders,
    respHeaders: respHeaders,
    reqBody: reqBody,
    respBody: respBody,
  );
}

// ==================== 测试 ====================

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final List<String> clipboardWrites = <String>[];

  setUp(() {
    clipboardWrites.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        final args = call.arguments;
        if (args is Map && args['text'] is String) {
          clipboardWrites.add(args['text'] as String);
        }
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  group('纯函数：cURL 最小拼装', () {
    test('method / url / headers / body 均出现在等价 cURL', () {
      final curl = buildCaptureCurl(
        _detail(
          method: 'POST',
          url: 'https://example.com/api/login',
          reqHeaders: 'Content-Type: application/json\r\nX-Token: abc',
          reqBody: utf8.encode('{"u":"1"}'),
        ),
      );
      expect(curl, contains("curl -X POST 'https://example.com/api/login'"));
      expect(curl, contains("-H 'Content-Type: application/json'"));
      expect(curl, contains("-H 'X-Token: abc'"));
      expect(curl, contains("--data-raw '{\"u\":\"1\"}'"));
    });

    test('GET 不额外发 -X，空 body 不发 --data', () {
      final curl = buildCaptureCurl(
        _detail(method: 'GET', url: 'https://example.com/a'),
      );
      expect(curl.startsWith("curl 'https://example.com/a'"), isTrue);
      expect(curl.contains(' -X '), isFalse);
      expect(curl.contains('--data'), isFalse);
    });

    test('URL 为空时按 scheme/host 回退', () {
      final curl = buildCaptureCurl(
        _detail(method: 'GET', url: '', scheme: 'http', host: 'plain.test'),
      );
      expect(curl, contains('http://plain.test'));
    });

    test('单引号转义为 shell 安全序列', () {
      final curl = buildCaptureCurl(
        _detail(reqBody: utf8.encode("it's")),
      );
      expect(curl, contains(r"--data-raw 'it'\''s'"));
    });
  });

  group('纯函数：改写规则预填', () {
    test('预填 method / url + 当前响应作为 replace 初值', () {
      final prefill = captureRulePrefill(
        _detail(
          method: 'PUT',
          url: 'https://api.test/v2/item',
          statusCode: 201,
          respHeaders: 'X-Resp: 1',
          respBody: utf8.encode('{"ok":true}'),
        ),
      );
      expect(prefill.method, 'PUT');
      expect(prefill.url, 'https://api.test/v2/item');
      expect(prefill.replaceBody, '{"ok":true}');
      expect(prefill.statusCode, 201);
      expect(prefill.responseHeaders, 'X-Resp: 1');
    });
  });

  group('页面动作 → 注入接口', () {
    Future<void> tapAction(WidgetTester tester, String actionKey) async {
      await tester.tap(find.byKey(const Key('detail_actions_menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key(actionKey)));
      await tester.pumpAndSettle();
    }

    testWidgets('复制 cURL：写剪贴板 + 成功提示', (tester) async {
      final bridge = _FakeBridge();
      final binder = CaptureDetailActionBinder(bridge: bridge);
      await tester.pumpWidget(_host(ProxyCaptureDetailPage(
        recordId: 7,
        facade: _FakeDetailFacade(
          _detail(reqBody: utf8.encode('{"u":"1"}')),
        ),
        onCopyCurl: binder.onCopyCurl,
      )));
      await _settleLoad(tester);

      await tapAction(tester, 'action_copy_curl');

      expect(clipboardWrites, hasLength(1));
      final copied = clipboardWrites.single;
      expect(copied, contains('https://example.com/api/login'));
      expect(copied, contains("-H 'Content-Type: application/json'"));
      expect(copied, contains("--data-raw '{\"u\":\"1\"}'"));
      expect(find.text('已复制 cURL'), findsOneWidget);
      expect(bridge.saveCalls, 0); // 不误触发其它接口
      expect(tester.takeException(), isNull);
    });

    testWidgets('保存到请求调试：调用 saveToCollection 并带详情', (tester) async {
      final bridge = _FakeBridge();
      final binder = CaptureDetailActionBinder(bridge: bridge);
      final detail = _detail();
      await tester.pumpWidget(_host(ProxyCaptureDetailPage(
        recordId: 7,
        facade: _FakeDetailFacade(detail),
        onSaveToDebug: binder.onSaveToDebug,
      )));
      await _settleLoad(tester);

      await tapAction(tester, 'action_save_debug');

      expect(bridge.saveCalls, 1);
      expect(bridge.savedDetail?.recordId, 7);
      expect(bridge.savedDetail?.method, 'POST');
      expect(bridge.savedDetail?.url, 'https://example.com/api/login');
      expect(bridge.ruleCalls, 0); // 不误触发其它接口
      expect(find.text('已保存到请求调试'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('创建改写规则：预填 method/url + 当前响应后跳编辑器', (tester) async {
      final bridge = _FakeBridge();
      final binder = CaptureDetailActionBinder(bridge: bridge);
      await tester.pumpWidget(_host(ProxyCaptureDetailPage(
        recordId: 7,
        facade: _FakeDetailFacade(
          _detail(method: 'PUT', respBody: utf8.encode('{"ok":true}')),
        ),
        onCreateRewriteRule: binder.onCreateRewriteRule,
      )));
      await _settleLoad(tester);

      await tapAction(tester, 'action_create_rule');

      expect(bridge.ruleCalls, 1);
      expect(bridge.rulePrefill?.method, 'PUT');
      expect(bridge.rulePrefill?.url, 'https://example.com/api/login');
      expect(bridge.rulePrefill?.replaceBody, '{"ok":true}');
      expect(bridge.saveCalls, 0); // 不误触发其它接口
      expect(tester.takeException(), isNull);
    });

    testWidgets('Body「作为改写响应」：以该 body 作为 replace 初值', (tester) async {
      final bridge = _FakeBridge();
      final binder = CaptureDetailActionBinder(bridge: bridge);
      await tester.pumpWidget(_host(ProxyCaptureDetailPage(
        recordId: 7,
        facade: _FakeDetailFacade(
          _detail(respBody: utf8.encode('{"hello":1}')),
        ),
        onUseAsRewriteResponse: binder.onUseAsRewriteResponse,
      )));
      await _settleLoad(tester);

      await tester.tap(find.byKey(const Key('seg_response')));
      await tester.pump();
      await tester.pump();
      await tester.tap(find.byKey(const Key('body_rewrite_resp')));
      await tester.pump();

      expect(bridge.ruleCalls, 1);
      expect(bridge.rulePrefill?.replaceBody, '{"hello":1}');
      expect(tester.takeException(), isNull);
    });
  });

  group('失败路径：showError 不崩', () {
    Future<void> tapAction(WidgetTester tester, String actionKey) async {
      await tester.tap(find.byKey(const Key('detail_actions_menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key(actionKey)));
      await tester.pumpAndSettle();
    }

    testWidgets('store 写失败 → showError，无异常', (tester) async {
      final bridge = _FakeBridge()..failSave = true;
      final binder = CaptureDetailActionBinder(bridge: bridge);
      await tester.pumpWidget(_host(ProxyCaptureDetailPage(
        recordId: 7,
        facade: _FakeDetailFacade(_detail()),
        onSaveToDebug: binder.onSaveToDebug,
      )));
      await _settleLoad(tester);

      await tapAction(tester, 'action_save_debug');

      expect(find.textContaining('写库失败'), findsOneWidget);
      expect(find.text('已保存到请求调试'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('建规则失败 → showError，无异常', (tester) async {
      final bridge = _FakeBridge()..failRule = true;
      final binder = CaptureDetailActionBinder(bridge: bridge);
      await tester.pumpWidget(_host(ProxyCaptureDetailPage(
        recordId: 7,
        facade: _FakeDetailFacade(_detail()),
        onCreateRewriteRule: binder.onCreateRewriteRule,
      )));
      await _settleLoad(tester);

      await tapAction(tester, 'action_create_rule');

      expect(find.textContaining('建规则失败'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('未接线的生产桥 → showError，不静默成功', (tester) async {
      const binder = CaptureDetailActionBinder(bridge: UnavailableCaptureBridge());
      await tester.pumpWidget(_host(ProxyCaptureDetailPage(
        recordId: 7,
        facade: _FakeDetailFacade(_detail()),
        onSaveToDebug: binder.onSaveToDebug,
      )));
      await _settleLoad(tester);

      await tapAction(tester, 'action_save_debug');

      expect(find.text('已保存到请求调试'), findsNothing);
      expect(find.textContaining('尚未接线'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
