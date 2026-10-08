/// 「请求调试」KV 编辑器交互（plan todo 13）测试。
///
/// 覆盖验收标准：
/// - 提交最后一行的 name/value 后自动追加一个空行；
/// - 批量编辑弹层把多行 `key: value` / `key=value` 解析为行；
/// - 任一非法行 → 在 `request-editor-kv-bulk-error` 下展示错误且不动既有行；
/// - 拖拽重排后再编辑不抛异常且值保留；
/// - 删除行不抛「controller used after dispose」错误；
/// - 键 / 值 表头存在。
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

/// 假发送器：不触碰网络。
class _FakeSender implements DebugSender {
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
  }) async =>
      const DebugResponse(statusCode: 200, bodyText: 'ok', sizeBytes: 2);

  @override
  void close() {}
}

/// 测试门面：内存 store（不落盘）+ 假 sender。
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

_RecordingFacade _facade() =>
    _RecordingFacade(store: _memoryStore(), sender: _FakeSender());

/// 直接以编辑器为 home 挂载；先清空旧树，使「重载」场景重建 State。
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

/// 第 [i] 行「名称=值」。
String _paramPair(WidgetTester tester, int i) =>
    '${_paramName(tester, i)}=${_paramValue(tester, i)}';

/// 通过值 sheet 提交第 [i] 行参数值（触发该行提交 → 末行自动追加）。
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

/// 打开批量编辑弹层并输入 [text]。
Future<void> _openBulk(WidgetTester tester, String text) async {
  await tester.tap(find.byKey(const Key('request-editor-kv-bulk')));
  await tester.pumpAndSettle();
  await tester.enterText(
    find.byKey(const Key('request-editor-kv-bulk-input')),
    text,
  );
  await tester.pump();
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
      id: 'r-kv',
      name: 'kv',
      method: 'GET',
      url: url,
      query: query,
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('KV 编辑器 · 表头 / 自动追加', () {
    testWidgets('参数行上方存在 键 / 值 表头', (tester) async {
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

      expect(find.text('键'), findsOneWidget);
      expect(find.text('值'), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('提交最后一行 → 自动追加一个空行', (tester) async {
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

      expect(_paramRowCount(tester), 1);
      await _editParamValue(tester, 0, '2');

      expect(_paramRowCount(tester), 2, reason: '末行提交后应追加一个空行');
      expect(_paramName(tester, 0), 'a');
      expect(_paramValue(tester, 0), '2');
      expect(_paramName(tester, 1), '', reason: '追加的行应为空');
      // 空值行展示 hint「值」。
      expect(_paramValue(tester, 1), '值');
      expect(tester.takeException(), isNull);
    });
  });

  group('KV 编辑器 · 批量编辑', () {
    testWidgets('打开 kv-bulk 输入 3 行合法文本 → 生成 3 行', (tester) async {
      final facade = _facade();
      final collection = facade.store.addCollection(name: 'API');

      await _pumpEditor(tester, facade: facade, collectionId: collection.id);

      await _openBulk(tester, 'a: 1\nb=2\nc : 3');
      expect(
        find.byKey(const Key('request-editor-kv-bulk-input')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('request-editor-kv-bulk-error')), findsNothing);

      await tester.tap(find.byKey(const Key('request-editor-kv-bulk-confirm')));
      await tester.pumpAndSettle();

      expect(_paramRowCount(tester), 3);
      expect(_paramPair(tester, 0), 'a=1');
      expect(_paramPair(tester, 1), 'b=2');
      expect(_paramPair(tester, 2), 'c=3');
      expect(find.byKey(const Key('request-editor-kv-bulk-input')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('非法行 → kv-bulk-error 显示且既有行不变', (tester) async {
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
      expect(_paramRowCount(tester), 1);

      await _openBulk(tester, 'b: 2\n这不是一对');
      await tester.tap(find.byKey(const Key('request-editor-kv-bulk-confirm')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('request-editor-kv-bulk-error')),
        findsOneWidget,
        reason: '非法行必须在 error 键下给出反馈',
      );
      // 弹层仍打开、未导入。
      expect(
        find.byKey(const Key('request-editor-kv-bulk-input')),
        findsOneWidget,
      );
      expect(_paramRowCount(tester), 1, reason: '非法输入不得改动既有行');
      expect(_paramPair(tester, 0), 'a=1');
      expect(tester.takeException(), isNull);
    });
  });

  group('KV 编辑器 · 拖拽重排 / 删除', () {
    testWidgets('拖拽重排后再编辑不抛异常且值保留', (tester) async {
      final facade = _facade();
      final collection = facade.store.addCollection(name: 'API');
      final request = _seed(
        facade.store,
        collection.id,
        url: 'https://api.example/p?a=1&b=2',
      );

      await _pumpEditor(
        tester,
        facade: facade,
        request: request,
        collectionId: collection.id,
      );
      expect(_paramRowCount(tester), 2);

      // 拖动第 0 行的显式拖拽手柄向下，跨过第 1 行。
      final handle = find.byKey(const Key('request-editor-param-drag-0'));
      expect(handle, findsOneWidget);
      final gesture = await tester.startGesture(tester.getCenter(handle));
      await tester.pump();
      await gesture.moveBy(const Offset(0, 140));
      await tester.pumpAndSettle();
      await gesture.up();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      // 重排后行集合仍是 a=1 / b=2（顺序可变）。
      expect(
        <String>{_paramPair(tester, 0), _paramPair(tester, 1)},
        <String>{'a=1', 'b=2'},
      );

      // 编辑首行 → 不抛异常；被编辑行更新，另一行保留。
      final edited = _paramName(tester, 0);
      final untouched = _paramName(tester, 1);
      await _editParamValue(tester, 0, '9');
      expect(_paramName(tester, 0), edited);
      expect(_paramValue(tester, 0), '9');
      expect(_paramName(tester, 1), untouched);
      expect(_paramValue(tester, 1), untouched == 'a' ? '1' : '2');
      expect(tester.takeException(), isNull);
    });

    testWidgets('删除行不抛 disposed-controller 错误；剩余行仍可编辑', (tester) async {
      final facade = _facade();
      final collection = facade.store.addCollection(name: 'API');
      final request = _seed(
        facade.store,
        collection.id,
        url: 'https://api.example/p?a=1&b=2',
      );

      await _pumpEditor(
        tester,
        facade: facade,
        request: request,
        collectionId: collection.id,
      );
      expect(_paramRowCount(tester), 2);

      await tester.tap(find.byKey(const Key('request-editor-param-delete-0')));
      await tester.pumpAndSettle();

      expect(_paramRowCount(tester), 1);
      expect(_paramPair(tester, 0), 'b=2');
      expect(
        tester.takeException(),
        isNull,
        reason: '删除行不得抛 controller used after dispose',
      );

      // 剩余行仍可编辑（其 controller 未被误释放）。
      await _editParamValue(tester, 0, '7');
      expect(_paramPair(tester, 0), 'b=7');
      expect(tester.takeException(), isNull);
    });
  });
}
