/// 「请求调试」KV 编辑器交互（plan todo 16）测试。
///
/// 覆盖验收标准（Wave 6：行是只读键 / 值预览；长按行弹「编辑 / 删除」菜单；
/// 「编辑」与页脚「添加」共用键 + 值表单弹层；**无末行自动追加**）：
/// - 编辑末行**不**自动追加空行；「添加」经表单弹层新增一行；
/// - 长按行 → 「编辑」→ 表单预填并写回键 / 值；
/// - 长按行 → 「删除」→ 行移除且不抛「controller used after dispose」；
/// - 表单取消不改动该行；表单带「插入环境变量」按钮；
/// - 批量编辑弹层把多行 `key: value` / `key=value` 解析为行；
/// - 任一非法行 → 在 `request-editor-kv-bulk-error` 下展示错误且不动既有行；
/// - 开启排序模式后拖拽重排再编辑不抛异常且值保留；
/// - 键 / 值 表头存在。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/design/app_spacing.dart';
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
    DebugCancellationToken? cancelToken,
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

/// 第 [i] 行参数名（Wave 5 起为 display 预览的 [Text] 文本；空值显示 hint「参数名」）。
String _paramName(WidgetTester tester, int i) {
  final text = tester.widget<Text>(find.descendant(
    of: find.byKey(Key('request-editor-param-name-$i')),
    matching: find.byType(Text),
  ));
  return text.data ?? '';
}

/// 第 [i] 行参数值（display 预览的 [Text] 文本；空值显示 hint「值」）。
String _paramValue(WidgetTester tester, int i) {
  final text = tester.widget<Text>(find.descendant(
    of: find.byKey(Key('request-editor-param-value-$i')),
    matching: find.byType(Text),
  ));
  return text.data ?? '';
}

/// 第 [i] 行「名称=值」。
String _paramPair(WidgetTester tester, int i) =>
    '${_paramName(tester, i)}=${_paramValue(tester, i)}';

/// URL 自适应字段当前展示的文本。
Finder _urlDisplay(String url) => find.descendant(
      of: find.byKey(const Key('request-editor-url')),
      matching: find.text(url),
    );

/// 编辑第 [i] 行参数值（Wave 6）：长按行 → 「编辑」→ 键值表单弹层 → 完成。
///
/// 表单预填该行键 / 值，仅改写值字段；确认后写回行 controller 并
/// `_syncUrlFromParams`（参数回写显示 URL）。**无末行自动追加**。
Future<void> _editParamValue(WidgetTester tester, int i, String value) async {
  await tester.longPress(find.byKey(Key('request-editor-param-name-$i')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('request-editor-kv-row-edit')));
  await tester.pumpAndSettle();
  await tester.enterText(
    find.byKey(const Key('request-editor-kv-editor-value')),
    value,
  );
  await tester.tap(find.byKey(const Key('request-editor-kv-editor-confirm')));
  await tester.pumpAndSettle();
}

/// 通过页脚「添加参数」按钮 → 键值表单弹层新增一行（Wave 6，无自动追加）。
Future<void> _addParam(WidgetTester tester, String name, String value) async {
  await tester.tap(find.byKey(const Key('request-editor-params-add')));
  await tester.pumpAndSettle();
  await tester.enterText(
    find.byKey(const Key('request-editor-kv-editor-name')),
    name,
  );
  await tester.enterText(
    find.byKey(const Key('request-editor-kv-editor-value')),
    value,
  );
  await tester.tap(find.byKey(const Key('request-editor-kv-editor-confirm')));
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
  )!;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('KV 编辑器 · 表头 / 添加', () {
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

    testWidgets('编辑末行不自动追加；「添加参数」经表单新增一行', (tester) async {
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

      // 编辑既有末行：写回值，**不**自动追加空行（Wave 6 移除自动追加）。
      await _editParamValue(tester, 0, '2');
      expect(_paramRowCount(tester), 1, reason: '编辑末行不得自动追加空行');
      expect(_paramName(tester, 0), 'a');
      expect(_paramValue(tester, 0), '2');

      // 显式「添加参数」→ 表单弹层 → 新增第二行。
      await _addParam(tester, 'b', '3');
      expect(_paramRowCount(tester), 2);
      expect(_paramPair(tester, 0), 'a=2');
      expect(_paramPair(tester, 1), 'b=3');
      expect(tester.takeException(), isNull);
    });
  });

  group('KV 编辑器 · 长按「编辑 / 删除」菜单 + 表单', () {
    testWidgets('长按行 → 编辑 → 表单预填键 / 值并写回', (tester) async {
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
      expect(_paramPair(tester, 0), 'a=1');

      await tester.longPress(
        find.byKey(const Key('request-editor-param-name-0')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('request-editor-kv-row-edit')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('request-editor-kv-row-delete')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('request-editor-kv-row-edit')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('request-editor-kv-row-editor')),
        findsOneWidget,
      );

      // 表单预填该行的键 / 值。
      expect(
        tester
            .widget<TextField>(
              find.byKey(const Key('request-editor-kv-editor-name')),
            )
            .controller!
            .text,
        'a',
      );
      expect(
        tester
            .widget<TextField>(
              find.byKey(const Key('request-editor-kv-editor-value')),
            )
            .controller!
            .text,
        '1',
      );

      // 同时改写键与值 → 写回并回写显示 URL。
      await tester.enterText(
        find.byKey(const Key('request-editor-kv-editor-name')),
        'token',
      );
      await tester.enterText(
        find.byKey(const Key('request-editor-kv-editor-value')),
        'xyz',
      );
      await tester.tap(find.byKey(const Key('request-editor-kv-editor-confirm')));
      await tester.pumpAndSettle();

      expect(_paramRowCount(tester), 1);
      expect(_paramPair(tester, 0), 'token=xyz');
      expect(_urlDisplay('https://api.example/p?token=xyz'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('表单取消不改动该行', (tester) async {
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

      await tester.longPress(
        find.byKey(const Key('request-editor-param-name-0')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('request-editor-kv-row-edit')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('request-editor-kv-editor-value')),
        'discarded',
      );
      await tester.tap(find.byKey(const Key('request-editor-kv-editor-cancel')));
      await tester.pumpAndSettle();

      expect(_paramRowCount(tester), 1);
      expect(_paramPair(tester, 0), 'a=1', reason: '取消不得写回');
      expect(tester.takeException(), isNull);
    });

    testWidgets('键值表单带「插入环境变量」按钮并插入到值草稿', (tester) async {
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
        url: 'https://api.example/p?a=1',
      );

      await _pumpEditor(
        tester,
        facade: facade,
        request: request,
        collectionId: collection.id,
      );

      await tester.longPress(
        find.byKey(const Key('request-editor-param-name-0')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('request-editor-kv-row-edit')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('request-editor-insert-var')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('request-editor-insert-var')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('request-editor-insert-var-host')));
      await tester.pumpAndSettle();

      final valueText = tester
          .widget<TextField>(
            find.byKey(const Key('request-editor-kv-editor-value')),
          )
          .controller!
          .text;
      expect(valueText, '1{{host}}', reason: '插入必须命中表单值草稿');

      await tester.tap(find.byKey(const Key('request-editor-kv-editor-confirm')));
      await tester.pumpAndSettle();
      expect(_paramPair(tester, 0), 'a=1{{host}}');
      expect(tester.takeException(), isNull);
    });

    testWidgets('行操作 / 行编辑弹层内容左右各留 AppSpacing.xl 水平内边距', (tester) async {
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

      // 长按 → 行操作弹层（Wave 7：contentPadding == onlyHorizontalXL）。
      await tester.longPress(
        find.byKey(const Key('request-editor-param-name-0')),
      );
      await tester.pumpAndSettle();
      final actionsSheet =
          find.byKey(const Key('request-editor-kv-row-actions'));
      expect(actionsSheet, findsOneWidget);
      final actionsSheetLeft = tester.getTopLeft(actionsSheet).dx;
      final editTileLeft = tester
          .getTopLeft(find.byKey(const Key('request-editor-kv-row-edit')))
          .dx;
      expect(
        editTileLeft - actionsSheetLeft,
        closeTo(AppSpacing.xl, 1.0),
        reason: '行操作弹层内容应相对弹层左缘内缩 AppSpacing.xl',
      );

      // 「编辑」→ 行编辑表单弹层，其内容 TextField 同样内缩 AppSpacing.xl。
      await tester.tap(find.byKey(const Key('request-editor-kv-row-edit')));
      await tester.pumpAndSettle();
      final editorSheet =
          find.byKey(const Key('request-editor-kv-row-editor'));
      expect(editorSheet, findsOneWidget);
      final editorSheetLeft = tester.getTopLeft(editorSheet).dx;
      final nameFieldLeft = tester
          .getTopLeft(find.byKey(const Key('request-editor-kv-editor-name')))
          .dx;
      expect(
        nameFieldLeft - editorSheetLeft,
        closeTo(AppSpacing.xl, 1.0),
        reason: '行编辑弹层内容应相对弹层左缘内缩 AppSpacing.xl',
      );
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

      // Wave 5：拖拽手柄仅在排序模式下渲染，先开启排序。
      await tester.tap(find.byKey(const Key('request-editor-kv-sort')));
      await tester.pumpAndSettle();

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

      // Wave 5：长按行 → 统一底部弹层「删除」→ 确认后移除该行。
      await tester.longPress(
        find.byKey(const Key('request-editor-param-name-0')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('request-editor-kv-row-delete')));
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

  group('KV 编辑器 · 启用开关（参数 vs Cookie）', () {
    testWidgets('参数段渲染启用 Checkbox，Cookie 段不渲染', (tester) async {
      final facade = _facade();
      final collection = facade.store.addCollection(name: 'API');
      final request = facade.store.addRequest(
        collection.id,
        DebugRequest(
          id: 'r-kv',
          name: 'kv',
          method: 'GET',
          url: 'https://api.example/p?a=1',
          query: <DebugQueryParam>[
            const DebugQueryParam(name: 'a', value: '1'),
          ],
          cookies: <DebugCookie>[const DebugCookie(name: 'sid', value: 'x')],
        ),
      )!;

      await _pumpEditor(
        tester,
        facade: facade,
        request: request,
        collectionId: collection.id,
      );

      // 参数段（默认分段）：种入 1 行参数 → 应渲染启用 Checkbox（allowDisable: true）。
      expect(_paramRowCount(tester), 1);
      expect(
        find.byType(Checkbox),
        findsOneWidget,
        reason: '参数段应出现启用开关（allowDisable: true）',
      );

      // 切到 Cookie 段：Cookie 无 enabled 字段 → 不得渲染 Checkbox。
      await tester.tap(find.byKey(const Key('request-editor-segment-cookies')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('request-editor-cookie-name-0')),
        findsOneWidget,
        reason: 'Cookie 行应已渲染（确保非空列表，避免假阴性）',
      );
      expect(
        find.byType(Checkbox),
        findsNothing,
        reason: 'Cookie 段不得渲染启用开关（DebugCookie 无 enabled）',
      );
      expect(tester.takeException(), isNull);
    });
  });
}
