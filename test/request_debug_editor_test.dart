/// 「请求调试」集合树 + 请求编辑器（plan todo 31）测试。
///
/// 覆盖验收标准：
/// - 集合 CRUD（新建集合 / 新建请求 / 删除请求）经门面持久化，字段值精确；
/// - cURL 导入解析并写入集合；
/// - 环境变量替换（已定义解析、未定义保留并标记、不递归）；
/// - 未保存离开二次确认**确实拦截**（不确认不离开、编辑不丢）；
/// - 发送触发门面（环境替换后的 URL 到达 sender）。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/navigation/nav_key.dart';
import 'package:gstore/core/request_debug/debug_cookie_jar.dart';
import 'package:gstore/core/request_debug/debug_models.dart';
import 'package:gstore/core/request_debug/debug_response.dart';
import 'package:gstore/core/request_debug/debug_sender.dart';
import 'package:gstore/core/request_debug/request_debug_facade.dart';
import 'package:gstore/core/request_debug/request_debug_store.dart';
import 'package:gstore/page/request_debug/collection_section.dart';
import 'package:gstore/page/request_debug/request_editor_page.dart';

/// 假发送器：记录每次发送参数，返回受控响应；**不触碰网络**。
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
    bool followRedirects = true,
    Duration? timeout,
    bool useCookies = true,
  }) async {
    calls.add(<String, Object?>{
      'method': method,
      'url': url,
      'body': body,
      'headers': headers
          .where((h) => h.enabled && h.name.isNotEmpty)
          .map((h) => '${h.name}:${h.value}')
          .toList(),
      'useCookies': useCookies,
    });
    return response;
  }

  @override
  void close() {}
}

/// 测试门面：真实内存 store（不落盘）+ 假 sender；记录 save 调用。
///
/// widget 测试运行在 fake-async 时区，真实文件 IO 不会完成，故 [load]/[save]
/// 用空操作覆盖；store 的内存 CRUD 语义完整保留。
class _RecordingFacade extends DefaultRequestDebugFacade {
  _RecordingFacade({
    required RequestDebugStore store,
    required DebugSender sender,
  }) : super(store: store, sender: sender);

  int loadCalls = 0;
  int saveCalls = 0;

  @override
  Future<void> load() async {
    loadCalls++;
  }

  @override
  Future<bool> save() async {
    saveCalls++;
    return true;
  }
}

RequestDebugStore _memoryStore() =>
    RequestDebugStore(directoryProvider: () async => Directory.systemTemp);

_FakeSender _sender() => _FakeSender();

_RecordingFacade _facade({
  RequestDebugStore? store,
  DebugSender? sender,
}) =>
    _RecordingFacade(
      store: store ?? _memoryStore(),
      sender: sender ?? _sender(),
    );

/// 测试宿主：与生产相同全局通道（appNavigatorKey / scaffoldMessengerKey），
/// 使 [AppDialogs] 的统一底部弹层可在测试中真实呈现。
Widget _host(RequestDebugCollectionSection section) => MaterialApp(
      navigatorKey: appNavigatorKey,
      scaffoldMessengerKey: AppDialogs.scaffoldMessengerKey,
      home: Scaffold(body: section),
    );

/// 把编辑器压入导航栈（先在宿主页点「open-editor」，再进入编辑器）。
Future<void> _pumpEditor(
  WidgetTester tester, {
  required RequestDebugFacade facade,
  DebugRequest? request,
  String? collectionId,
}) async {
  await tester.pumpWidget(MaterialApp(
    navigatorKey: appNavigatorKey,
    scaffoldMessengerKey: AppDialogs.scaffoldMessengerKey,
    home: Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          key: const Key('open-editor'),
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => RequestEditorPage(
                facade: facade,
                request: request,
                collectionId: collectionId,
              ),
            ),
          ),
          child: const Text('open-editor'),
        ),
      ),
    ),
  ));
  await tester.tap(find.byKey(const Key('open-editor')));
  await tester.pumpAndSettle();
}

/// 取高亮预览（Text.rich）的纯文本，供环境替换断言。
String _previewText(WidgetTester tester) {
  final text = tester.widget<Text>(
    find.byKey(const Key('request-editor-url-preview')),
  );
  return text.textSpan?.toPlainText() ?? text.data ?? '';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('集合分区（集合树 + 请求列表）', () {
    testWidgets('新建集合 → 通过门面持久化（名称精确、触发 save）', (tester) async {
      final facade = _facade();
      await tester.pumpWidget(_host(RequestDebugCollectionSection(facade: facade)));
      await tester.pumpAndSettle();

      // 空态。
      expect(find.text('暂无集合'), findsOneWidget);

      await tester.tap(find.byKey(const Key('request-debug-collection-add')));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('request-debug-prompt-field')),
        'API',
      );
      await tester.tap(find.byKey(const Key('request-debug-prompt-confirm')));
      await tester.pumpAndSettle();

      expect(facade.store.collections, hasLength(1));
      expect(facade.store.collections.single.name, 'API');
      expect(facade.saveCalls, greaterThanOrEqualTo(1));
      expect(find.text('API'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('文件夹新建请求 → 编辑器保存 → 请求进入该集合（字段精确）',
        (tester) async {
      final facade = _facade();
      final collection = facade.store.addCollection(name: 'API');
      await tester.pumpWidget(_host(RequestDebugCollectionSection(facade: facade)));
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(Key('request-debug-collection-menu-${collection.id}')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(Key('request-debug-collection-new-request-${collection.id}')),
      );
      await tester.pumpAndSettle();

      // 编辑器已打开（新建草稿）。
      expect(find.byKey(const Key('request-editor-url')), findsOneWidget);

      await tester.enterText(find.byKey(const Key('request-editor-name')), '登录');
      await tester.enterText(
        find.byKey(const Key('request-editor-url')),
        'https://api.example/login',
      );
      await tester.tap(find.byKey(const Key('request-editor-method')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('POST').last);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('request-editor-save')));
      await tester.pumpAndSettle();

      final saved = facade.store.collectionById(collection.id)!.requests;
      expect(saved, hasLength(1));
      expect(saved.single.name, '登录');
      expect(saved.single.url, 'https://api.example/login');
      expect(saved.single.method, 'POST');
      expect(saved.single.collectionId, collection.id);
      expect(facade.saveCalls, greaterThanOrEqualTo(1));
      expect(tester.takeException(), isNull);
    });

    testWidgets('删除请求 → 从集合移除', (tester) async {
      final facade = _facade();
      final collection = facade.store.addCollection(name: 'API');
      final request = facade.store.addRequest(
        collection.id,
        DebugRequest(id: 'r-del', name: 'del', url: 'https://a.example/x'),
      );
      await tester.pumpWidget(_host(RequestDebugCollectionSection(facade: facade)));
      await tester.pumpAndSettle();

      expect(find.byKey(Key('request-debug-request-${request.id}')), findsOneWidget);

      await tester.tap(
        find.byKey(Key('request-debug-request-menu-${request.id}')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(Key('request-debug-request-delete-${request.id}')),
      );
      await tester.pumpAndSettle();

      expect(facade.store.requestById(request.id), isNull);
      expect(find.text('暂无请求'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('导入 cURL → 解析并写入集合（方法 / URL / Body 精确）',
        (tester) async {
      final facade = _facade();
      await tester.pumpWidget(_host(RequestDebugCollectionSection(facade: facade)));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('request-debug-curl-import')));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('request-debug-curl-field')),
        "curl -X POST https://api.example/x "
            "-H 'Content-Type: application/json' -d '{\"a\":1}'",
      );
      await tester.tap(find.byKey(const Key('request-debug-curl-confirm')));
      await tester.pumpAndSettle();

      final host = facade.store.collections
          .firstWhere((c) => c.name == '导入');
      expect(host.requests, hasLength(1));
      final imported = host.requests.single;
      expect(imported.method, 'POST');
      expect(imported.url, 'https://api.example/x');
      expect(imported.bodyKind, DebugBodyKind.json);
      expect(imported.body, '{"a":1}');
      expect(facade.saveCalls, greaterThanOrEqualTo(1));
      expect(tester.takeException(), isNull);
    });
  });

  group('请求编辑器 · 发送', () {
    testWidgets('发送触发门面，环境变量替换后的 URL 到达 sender', (tester) async {
      final sender = _sender();
      final facade = _facade(sender: sender);
      final env = facade.store.addEnvironment(
        name: 'dev',
        vars: <String, String>{'host': 'https://api.example'},
      );
      facade.store.setActiveEnvironment(env.id);
      final collection = facade.store.addCollection(name: 'API');
      final request = facade.store.addRequest(
        collection.id,
        DebugRequest(
          id: 'r-send',
          name: 'send',
          method: 'GET',
          url: '{{host}}/v1',
        ),
      );

      await _pumpEditor(
        tester,
        facade: facade,
        request: request,
        collectionId: collection.id,
      );

      await tester.tap(find.byKey(const Key('request-editor-send')));
      await tester.pumpAndSettle();

      expect(sender.calls, hasLength(1));
      expect(sender.calls.single['url'], 'https://api.example/v1');
      expect(sender.calls.single['method'], 'GET');

      // 切到「响应」分段并显示状态码。
      final status = tester.widget<Text>(
        find.byKey(const Key('request-editor-response-status')),
      );
      expect(status.data, '200');
      expect(tester.takeException(), isNull);
    });
  });

  group('请求编辑器 · 保存', () {
    testWidgets('保存写入精确字段，且保存后离开不再二次确认', (tester) async {
      final facade = _facade();
      final collection = facade.store.addCollection(name: 'API');

      await _pumpEditor(tester, facade: facade, collectionId: collection.id);

      await tester.enterText(find.byKey(const Key('request-editor-name')), '创建用户');
      await tester.enterText(
        find.byKey(const Key('request-editor-url')),
        'https://api.example/users',
      );
      await tester.tap(find.byKey(const Key('request-editor-method')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('POST').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('request-editor-save')));
      await tester.pumpAndSettle();

      final saved = facade.store.collectionById(collection.id)!.requests;
      expect(saved, hasLength(1));
      expect(saved.single.name, '创建用户');
      expect(saved.single.url, 'https://api.example/users');
      expect(saved.single.method, 'POST');
      expect(saved.single.collectionId, collection.id);

      // 已保存（不再 dirty）→ 返回直接离开，无二次确认。
      await tester.tap(find.byKey(const Key('request-editor-back')));
      await tester.pumpAndSettle();
      expect(find.text('放弃未保存的修改？'), findsNothing);
      expect(find.byKey(const Key('open-editor')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('另存为生成副本（新 id、名称含副本）', (tester) async {
      final facade = _facade();
      final collection = facade.store.addCollection(name: 'API');
      final request = facade.store.addRequest(
        collection.id,
        DebugRequest(
          id: 'r-copy',
          name: '源请求',
          method: 'GET',
          url: 'https://api.example/a',
        ),
      );

      await _pumpEditor(
        tester,
        facade: facade,
        request: request,
        collectionId: collection.id,
      );

      await tester.tap(find.byKey(const Key('request-editor-save-as')));
      await tester.pumpAndSettle();

      final requests = facade.store.collectionById(collection.id)!.requests;
      expect(requests, hasLength(2));
      final clone = requests.firstWhere((r) => r.id != request.id);
      expect(clone.id, isNot(request.id));
      expect(clone.name, contains('副本'));
      expect(clone.url, 'https://api.example/a');
      expect(tester.takeException(), isNull);
    });

    testWidgets('导出 cURL → 展示等价命令', (tester) async {
      final facade = _facade();
      final collection = facade.store.addCollection(name: 'API');
      final request = facade.store.addRequest(
        collection.id,
        DebugRequest(
          id: 'r-curl',
          name: 'curl',
          method: 'GET',
          url: 'https://api.example/x',
        ),
      );

      await _pumpEditor(
        tester,
        facade: facade,
        request: request,
        collectionId: collection.id,
      );

      await tester.tap(find.byKey(const Key('request-editor-export-curl')));
      await tester.pumpAndSettle();

      expect(find.textContaining('curl'), findsWidgets);
      expect(find.textContaining('https://api.example/x'), findsWidgets);
      expect(tester.takeException(), isNull);
    });
  });

  group('请求编辑器 · 未保存离开二次确认', () {
    testWidgets('有未保存编辑时返回 → 确认拦截；继续编辑不离开；放弃才离开',
        (tester) async {
      final facade = _facade();
      final collection = facade.store.addCollection(name: 'API');
      final request = facade.store.addRequest(
        collection.id,
        DebugRequest(
          id: 'r-unsaved',
          name: 'unsaved',
          method: 'GET',
          url: 'https://api.example/old',
        ),
      );

      await _pumpEditor(
        tester,
        facade: facade,
        request: request,
        collectionId: collection.id,
      );

      // 编辑 URL → dirty。
      await tester.enterText(
        find.byKey(const Key('request-editor-url')),
        'https://api.example/new',
      );
      await tester.pumpAndSettle();

      // 返回 → 弹出二次确认。
      await tester.tap(find.byKey(const Key('request-editor-back')));
      await tester.pumpAndSettle();
      expect(find.text('放弃未保存的修改？'), findsOneWidget);

      // 选择「继续编辑」→ 不离开，编辑保留，未落盘。
      await tester.tap(find.text('继续编辑'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('open-editor')), findsNothing);
      expect(find.byKey(const Key('request-editor-url')), findsOneWidget);
      final urlField = tester.widget<TextField>(
        find.byKey(const Key('request-editor-url')),
      );
      expect(urlField.controller!.text, 'https://api.example/new');
      expect(
        facade.store.requestById('r-unsaved')!.url,
        'https://api.example/old',
        reason: '未保存编辑绝不能静默落盘',
      );

      // 再次返回 → 选择「放弃」→ 才真正离开。
      await tester.tap(find.byKey(const Key('request-editor-back')));
      await tester.pumpAndSettle();
      expect(find.text('放弃未保存的修改？'), findsOneWidget);
      await tester.tap(find.text('放弃'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('open-editor')), findsOneWidget);
      expect(find.byKey(const Key('request-editor-url')), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('请求编辑器 · 环境变量', () {
    testWidgets('已定义解析、未定义保留并标记、且不递归', (tester) async {
      final facade = _facade();
      final env = facade.store.addEnvironment(
        name: 'dev',
        vars: <String, String>{
          'host': 'https://api.example',
          'nested': '{{host}}',
        },
      );
      facade.store.setActiveEnvironment(env.id);
      final collection = facade.store.addCollection(name: 'API');
      final request = facade.store.addRequest(
        collection.id,
        DebugRequest(
          id: 'r-env',
          name: 'env',
          method: 'GET',
          url: '{{host}}/v1?m={{missing}}',
        ),
      );

      await _pumpEditor(
        tester,
        facade: facade,
        request: request,
        collectionId: collection.id,
      );

      // 已定义替换；未定义保留原样。
      expect(
        _previewText(tester),
        'https://api.example/v1?m={{missing}}',
      );
      // 未定义变量被标记（chip 存在）。
      expect(
        find.byKey(const Key('request-editor-env-missing-missing')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('request-editor-env-missing-host')),
        findsNothing,
      );

      // 不递归：值 `{{host}}` 不再展开，也不计入缺失。
      await tester.enterText(
        find.byKey(const Key('request-editor-url')),
        '{{nested}}',
      );
      await tester.pumpAndSettle();
      expect(_previewText(tester), '{{host}}');
      expect(
        find.byKey(const Key('request-editor-env-missing-host')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('插入变量 → 追加 `{{name}}` 到 URL 并高亮解析', (tester) async {
      final facade = _facade();
      final env = facade.store.addEnvironment(
        name: 'dev',
        vars: <String, String>{'host': 'https://api.example'},
      );
      facade.store.setActiveEnvironment(env.id);
      final collection = facade.store.addCollection(name: 'API');
      final request = facade.store.addRequest(
        collection.id,
        DebugRequest(
          id: 'r-insert',
          name: 'insert',
          method: 'GET',
          url: 'https://api.example/',
        ),
      );

      await _pumpEditor(
        tester,
        facade: facade,
        request: request,
        collectionId: collection.id,
      );

      await tester.tap(find.byKey(const Key('request-editor-insert-var')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('request-editor-insert-var-host')),
      );
      await tester.pumpAndSettle();

      final urlField = tester.widget<TextField>(
        find.byKey(const Key('request-editor-url')),
      );
      expect(urlField.controller!.text, 'https://api.example/{{host}}');
      expect(_previewText(tester), 'https://api.example/https://api.example');
      expect(tester.takeException(), isNull);
    });
  });

  group('设计系统约束', () {
    testWidgets('编辑器分区使用 AppSegmentedButton（分段 参数/头/体/认证/Cookie/响应）',
        (tester) async {
      final facade = _facade();
      final collection = facade.store.addCollection(name: 'API');
      await _pumpEditor(tester, facade: facade, collectionId: collection.id);

      expect(find.text('参数'), findsOneWidget);
      expect(find.text('头'), findsOneWidget);
      expect(find.text('体'), findsOneWidget);
      expect(find.text('认证'), findsOneWidget);
      expect(find.text('Cookie'), findsOneWidget);
      expect(find.text('响应'), findsOneWidget);

      await tester.tap(find.byKey(const Key('request-editor-segment-headers')));
      await tester.pumpAndSettle();
      expect(find.text('添加请求头'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
