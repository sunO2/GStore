/// 「请求调试」URL ⇄ 参数 双向同步（plan todo 12）测试。
///
/// 覆盖验收标准：
/// - 载入时始终解析 URL；`request.query` 非空时按 `mergeParams` 合并
///   （URL 独有键保留、同名键以 query 为准）；
/// - URL 提交（粘贴 / 弹层完成）同步为参数行；参数编辑 / 增删回写显示 URL；
/// - 规范化持久化：`url` = path + `#fragment`（query 移入 `query[]`）；
/// - `{{var}}` 在解析 / 同步阶段始终字面保留，不提前解析；
/// - 重入保护：连续编辑不振荡；非法 / 局部 URL 提交不抛且行不变。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/navigation/nav_key.dart';
import 'package:gstore/core/request_debug/debug_cookie_jar.dart';
import 'package:gstore/core/request_debug/debug_models.dart';
import 'package:gstore/core/request_debug/debug_response.dart';
import 'package:gstore/core/request_debug/debug_sender.dart';
import 'package:gstore/core/request_debug/request_debug_facade.dart';
import 'package:gstore/core/request_debug/request_debug_store.dart';
import 'package:gstore/page/request_debug/request_editor_page.dart';

/// 假发送器：记录每次发送参数（含 query），返回受控响应；**不触碰网络**。
class _FakeSender implements DebugSender {
  final List<Map<String, Object?>> calls = <Map<String, Object?>>[];

  DebugResponse response = const DebugResponse(
    statusCode: 200,
    bodyText: 'ok',
    sizeBytes: 2,
  );

  @override
  final DebugCookieJar cookieJar = DebugCookieJar();

  @override
  Future<DebugResponse> send({
    required String method,
    required String url,
    List<DebugHeader> headers = const <DebugHeader>[],
    List<DebugQueryParam> query = const <DebugQueryParam>[],
    String body = '',
    List<int>? bodyBytes,
    bool followRedirects = true,
    Duration? timeout,
    bool useCookies = true,
    bool skipTlsVerify = false,
    DebugCancellationToken? cancelToken,
  }) async {
    calls.add(<String, Object?>{
      'method': method,
      'url': url,
      'body': body,
      'query': query.map((q) => '${q.name}=${q.value}').toList(),
    });
    return response;
  }

  @override
  void close() {}
}

/// 测试门面：真实内存 store（不落盘）+ 假 sender；记录 save 调用。
class _RecordingFacade extends DefaultRequestDebugFacade {
  _RecordingFacade({required super.store, required super.sender});

  int saveCalls = 0;

  @override
  Future<void> load() async {}

  @override
  Future<bool> save() async {
    saveCalls++;
    return true;
  }
}

RequestDebugStore _memoryStore() =>
    RequestDebugStore(directoryProvider: () async => Directory.systemTemp);

_RecordingFacade _facade({RequestDebugStore? store, DebugSender? sender}) =>
    _RecordingFacade(
      store: store ?? _memoryStore(),
      sender: sender ?? _FakeSender(),
    );

/// 直接以编辑器为 home 挂载；每次先清空旧树，使「重载」场景重建 State。
Future<void> _pumpEditor(
  WidgetTester tester, {
  required RequestDebugFacade facade,
  DebugRequest? request,
  String? collectionId,
}) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpWidget(MaterialApp(
    navigatorKey: appNavigatorKey,
    scaffoldMessengerKey: AppDialogs.scaffoldMessengerKey,
    home: RequestEditorPage(
      facade: facade,
      request: request,
      collectionId: collectionId,
    ),
  ));
  await tester.pumpAndSettle();
}

/// URL 自适应字段当前展示的文本。
Finder _urlDisplay(String url) => find.descendant(
      of: find.byKey(const Key('request-editor-url')),
      matching: find.text(url),
    );

/// 当前参数行数（按索引键连续探测）。
int _paramRowCount(WidgetTester tester) {
  var n = 0;
  while (find
      .byKey(Key('request-editor-param-name-$n'))
      .evaluate()
      .isNotEmpty) {
    n++;
  }
  return n;
}

/// 第 [i] 行参数名（行内输入框的 controller 文本）。
String _paramName(WidgetTester tester, int i) {
  final field = tester.widget<TextField>(find.descendant(
    of: find.byKey(Key('request-editor-param-name-$i')),
    matching: find.byType(TextField),
  ));
  return field.controller!.text;
}

/// 第 [i] 行参数值（sheet 模式展示文本）。
String _paramValue(WidgetTester tester, int i) {
  final text = tester.widget<Text>(find.descendant(
    of: find.byKey(Key('request-editor-param-value-$i')),
    matching: find.byType(Text),
  ));
  return text.data ?? text.textSpan?.toPlainText() ?? '';
}

/// 通过 URL 自适应弹层提交 URL。
///
/// T15 起 URL 提交（弹层完成）会 sync-then-send 并自动切到「响应」分段；本套
/// 用例只验证 URL⇄参数同步，故提交后切回「参数」分段继续断言参数行。
Future<void> _setUrlViaSheet(WidgetTester tester, String url) async {
  await tester.tap(find.byKey(const Key('request-editor-url')));
  await tester.pumpAndSettle();
  await tester.enterText(
    find.byKey(const Key('request-editor-field-sheet-input')),
    url,
  );
  await tester.tap(find.byKey(const Key('request-editor-field-sheet-confirm')));
  await tester.pumpAndSettle();
  final paramsTab = find.byKey(const Key('request-editor-segment-params'));
  if (paramsTab.evaluate().isNotEmpty) {
    await tester.tap(paramsTab);
    await tester.pumpAndSettle();
  }
}

/// 通过值 sheet 提交第 [i] 行参数值。
Future<void> _editParamValue(WidgetTester tester, int i, String value) async {
  await tester.tap(find.byKey(Key('request-editor-param-value-$i')));
  await tester.pumpAndSettle();
  await tester.enterText(
    find.byKey(const Key('request-editor-field-sheet-input')),
    value,
  );
  await tester.tap(find.byKey(const Key('request-editor-field-sheet-confirm')));
  await tester.pumpAndSettle();
}

/// 在集合中种入一个待编辑请求。
DebugRequest _seed(
  RequestDebugStore store,
  String collectionId, {
  required String url,
  List<DebugQueryParam> query = const <DebugQueryParam>[],
}) {
  return store.addRequest(
    collectionId,
    DebugRequest(
      id: 'r-sync',
      name: 'sync',
      method: 'GET',
      url: url,
      query: query,
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('URL⇄参数同步', () {
    testWidgets('载入 url ?a=1 + query [a=2] → 行恰为 [a=2]', (tester) async {
      final facade = _facade();
      final collection = facade.store.addCollection(name: 'API');
      final request = _seed(
        facade.store,
        collection.id,
        url: 'https://api.example/p?a=1',
        query: const <DebugQueryParam>[DebugQueryParam(name: 'a', value: '2')],
      );

      await _pumpEditor(
        tester,
        facade: facade,
        request: request,
        collectionId: collection.id,
      );

      expect(_paramRowCount(tester), 1);
      expect(_paramName(tester, 0), 'a');
      expect(_paramValue(tester, 0), '2');
      expect(_urlDisplay('https://api.example/p?a=2'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('载入 legacy url ?a=1&b=2 + query [a=2] → 行 [a=2, b=2]（保留 URL 独有键）',
        (tester) async {
      final facade = _facade();
      final collection = facade.store.addCollection(name: 'API');
      final request = _seed(
        facade.store,
        collection.id,
        url: 'https://api.example/p?a=1&b=2',
        query: const <DebugQueryParam>[DebugQueryParam(name: 'a', value: '2')],
      );

      await _pumpEditor(
        tester,
        facade: facade,
        request: request,
        collectionId: collection.id,
      );

      expect(_paramRowCount(tester), 2);
      expect(_paramName(tester, 0), 'a');
      expect(_paramValue(tester, 0), '2');
      expect(_paramName(tester, 1), 'b');
      expect(_paramValue(tester, 1), '2');
      expect(_urlDisplay('https://api.example/p?a=2&b=2'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('提交 URL ?a=1&b=2 → 2 行', (tester) async {
      final facade = _facade();
      final collection = facade.store.addCollection(name: 'API');

      await _pumpEditor(tester, facade: facade, collectionId: collection.id);
      await _setUrlViaSheet(tester, 'https://api.example/p?a=1&b=2');

      expect(_paramRowCount(tester), 2);
      expect(_paramName(tester, 0), 'a');
      expect(_paramValue(tester, 0), '1');
      expect(_paramName(tester, 1), 'b');
      expect(_paramValue(tester, 1), '2');
      expect(_urlDisplay('https://api.example/p?a=1&b=2'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('编辑行值 → URL 仅更新一次（无振荡）', (tester) async {
      final facade = _facade();
      final collection = facade.store.addCollection(name: 'API');
      final request = _seed(
        facade.store,
        collection.id,
        url: 'https://api.example/p?a=1',
      );

      await _pumpEditor(
        tester,
        facade: facade,
        request: request,
        collectionId: collection.id,
      );

      await _editParamValue(tester, 0, '2');

      expect(_urlDisplay('https://api.example/p?a=2'), findsOneWidget);
      expect(_urlDisplay('https://api.example/p?a=1'), findsNothing);

      // 再泵一帧：URL 不应回弹 / 振荡。
      await tester.pump();
      expect(_urlDisplay('https://api.example/p?a=2'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('保存规范化：url = path#frag（无 ?），query 精确；重载行一致',
        (tester) async {
      final facade = _facade();
      final collection = facade.store.addCollection(name: 'API');

      await _pumpEditor(tester, facade: facade, collectionId: collection.id);
      await _setUrlViaSheet(tester, 'https://api.example/p?a=1&b=2#frag');
      expect(_paramRowCount(tester), 2);

      await tester.tap(find.byKey(const Key('request-editor-more')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('request-editor-save')));
      await tester.pumpAndSettle();

      final saved = facade.store.collectionById(collection.id)!.requests.single;
      expect(saved.url, 'https://api.example/p#frag');
      expect(saved.url.contains('?'), isFalse);
      expect(saved.query, hasLength(2));
      expect(saved.query[0].name, 'a');
      expect(saved.query[0].value, '1');
      expect(saved.query[1].name, 'b');
      expect(saved.query[1].value, '2');

      // 重载保存后的请求 → 行完全一致、显示 URL 仍带合并查询。
      await _pumpEditor(
        tester,
        facade: facade,
        request: saved,
        collectionId: collection.id,
      );

      expect(_paramRowCount(tester), 2);
      expect(_paramName(tester, 0), 'a');
      expect(_paramValue(tester, 0), '1');
      expect(_paramName(tester, 1), 'b');
      expect(_paramValue(tester, 1), '2');
      expect(_urlDisplay('https://api.example/p?a=1&b=2#frag'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('占位符字面保留：跳过同步解析，保存后 url/query 仍含 {{...}}',
        (tester) async {
      final facade = _facade();
      final env = facade.store.addEnvironment(
        name: 'dev',
        vars: <String, String>{'host': 'https://api.example'},
      );
      facade.store.setActiveEnvironment(env.id);
      final collection = facade.store.addCollection(name: 'API');
      final request = _seed(
        facade.store,
        collection.id,
        url: '{{host}}/v1?m={{missing}}',
      );

      await _pumpEditor(
        tester,
        facade: facade,
        request: request,
        collectionId: collection.id,
      );

      expect(_urlDisplay('{{host}}/v1?m={{missing}}'), findsOneWidget);
      expect(_paramName(tester, 0), 'm');
      expect(_paramValue(tester, 0), '{{missing}}');

      await tester.tap(find.byKey(const Key('request-editor-more')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('request-editor-save')));
      await tester.pumpAndSettle();

      final saved = facade.store.requestById('r-sync')!;
      expect(saved.url, '{{host}}/v1');
      expect(saved.query, hasLength(1));
      expect(saved.query.single.name, 'm');
      expect(saved.query.single.value, '{{missing}}');
      expect(tester.takeException(), isNull);
    });
  });

  group('URL⇄参数同步 · QA', () {
    testWidgets('3 次连续编辑稳定（无振荡）', (tester) async {
      final facade = _facade();
      final collection = facade.store.addCollection(name: 'API');
      final request = _seed(
        facade.store,
        collection.id,
        url: 'https://api.example/p?a=1&b=1',
      );

      await _pumpEditor(
        tester,
        facade: facade,
        request: request,
        collectionId: collection.id,
      );

      await _editParamValue(tester, 0, '11');
      expect(_urlDisplay('https://api.example/p?a=11&b=1'), findsOneWidget);

      await _editParamValue(tester, 1, '22');
      expect(_urlDisplay('https://api.example/p?a=11&b=22'), findsOneWidget);

      await _editParamValue(tester, 0, '33');
      expect(_urlDisplay('https://api.example/p?a=33&b=22'), findsOneWidget);

      // 稳定：额外帧不回弹。
      await tester.pump();
      expect(_urlDisplay('https://api.example/p?a=33&b=22'), findsOneWidget);
      // T13：提交末行（b）后自动追加一个空行，故为 3 行；空名行不入 URL。
      expect(_paramRowCount(tester), 3);
      expect(tester.takeException(), isNull);
    });

    testWidgets('非法 / 局部 URL 提交不抛且行不变', (tester) async {
      final facade = _facade();
      final collection = facade.store.addCollection(name: 'API');
      final request = _seed(
        facade.store,
        collection.id,
        url: 'https://api.example/p?a=1',
      );

      await _pumpEditor(
        tester,
        facade: facade,
        request: request,
        collectionId: collection.id,
      );

      // 局部 URL（无查询）。
      await _setUrlViaSheet(tester, 'https://api.example/');
      expect(_paramRowCount(tester), 1);
      expect(_paramName(tester, 0), 'a');
      expect(_paramValue(tester, 0), '1');

      // 非法百分号序列：parseUrlQuery 兜底不抛，行保持不变。
      await _setUrlViaSheet(tester, 'https://api.example/p?x=%ZZ');
      expect(_paramRowCount(tester), 1);
      expect(_paramName(tester, 0), 'a');
      expect(_paramValue(tester, 0), '1');
      expect(tester.takeException(), isNull);
    });
  });
}
