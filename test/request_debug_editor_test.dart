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
import 'package:gstore/page/request_debug/history_section.dart';
import 'package:gstore/page/request_debug/request_editor_page.dart';

/// 假发送器：记录每次发送参数，返回受控响应；**不触碰网络**。
class _FakeSender implements DebugSender {
  final List<Map<String, Object?>> calls = <Map<String, Object?>>[];

  DebugResponse response = const DebugResponse(
    statusCode: 200,
    bodyText: 'ok',
    sizeBytes: 2,
  );

  /// 为 `true` 时发送挂起直到 `cancelToken` 被取消，返回结构化「已取消」。
  bool blockUntilCancelled = false;

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
    if (blockUntilCancelled && cancelToken != null) {
      await cancelToken.whenCancelled;
      return DebugResponse.cancelled();
    }
    calls.add(<String, Object?>{
      'method': method,
      'url': url,
      'body': body,
      'headers': headers
          .where((h) => h.enabled && h.name.isNotEmpty)
          .map((h) => '${h.name}:${h.value}')
          .toList(),
      'query': query
          .where((q) => q.enabled && q.name.isNotEmpty)
          .map((q) => '${q.name}=${q.value}')
          .toList(),
      'useCookies': useCookies,
      'followRedirects': followRedirects,
      'timeoutMs': timeout?.inMilliseconds,
      'skipTlsVerify': skipTlsVerify,
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

/// 通过 URL 的自适应弹层设置 URL 值（tap 字段 → 弹层输入 → 完成）。
Future<void> _setUrlViaSheet(WidgetTester tester, String url) async {
  await tester.tap(find.byKey(const Key('request-editor-url')));
  await tester.pumpAndSettle();
  await tester.enterText(
    find.byKey(const Key('request-editor-field-sheet-input')),
    url,
  );
  await tester.tap(find.byKey(const Key('request-editor-field-sheet-confirm')));
  await tester.pumpAndSettle();
}

/// 打开右上「更多」溢出菜单并点选其中一项（保存 / 另存为 / 导出 cURL）。
Future<void> _tapMore(WidgetTester tester, Key itemKey) async {
  await tester.tap(find.byKey(const Key('request-editor-more')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(itemKey));
  await tester.pumpAndSettle();
}

/// 打开「更多 → 网络选项」底部弹层。
Future<void> _openNetworkOptions(WidgetTester tester) =>
    _tapMore(tester, const Key('request-editor-network-options'));

/// 读取网络选项弹层中某个开关的当前值。
bool _switchValue(WidgetTester tester, String key) =>
    tester.widget<SwitchListTile>(find.byKey(Key(key))).value;

/// URL 自适应字段当前展示的文本。
Finder _urlDisplay(String url) => find.descendant(
      of: find.byKey(const Key('request-editor-url')),
      matching: find.text(url),
    );

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
      await _setUrlViaSheet(tester, 'https://api.example/login');
      await tester.tap(find.byKey(const Key('request-editor-method')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('POST').last);
      await tester.pumpAndSettle();

      await _tapMore(tester, const Key('request-editor-save'));

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
      )!;
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
      )!;

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

    testWidgets('仅一个发送入口：底部 request-editor-send，无顶部按钮', (tester) async {
      final facade = _facade();
      final collection = facade.store.addCollection(name: 'API');

      await _pumpEditor(tester, facade: facade, collectionId: collection.id);

      expect(find.byKey(const Key('request-editor-send')), findsOneWidget);
      expect(find.byKey(const Key('request-editor-send-top')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('URL 弹层 done：先同步新查询参数再发送，且仅发送一次', (tester) async {
      final sender = _sender();
      final facade = _facade(sender: sender);
      final collection = facade.store.addCollection(name: 'API');
      final request = facade.store.addRequest(
        collection.id,
        DebugRequest(
          id: 'r-submit',
          name: 'submit',
          method: 'GET',
          url: 'https://api.example/search',
        ),
      )!;

      await _pumpEditor(
        tester,
        facade: facade,
        request: request,
        collectionId: collection.id,
      );

      // 打开 URL 弹层，输入带查询的地址，按键盘 done（提交并触发发送）。
      await tester.tap(find.byKey(const Key('request-editor-url')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('request-editor-field-sheet-input')),
        'https://api.example/search?a=1&b=2',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      // 编辑面已关闭。
      expect(find.byKey(const Key('request-editor-field-sheet')), findsNothing);
      // 恰好发送一次，且带上刚输入的查询参数（sync-before-send）。
      expect(sender.calls, hasLength(1));
      expect(sender.calls.single['url'], 'https://api.example/search');
      expect(
        sender.calls.single['query'],
        containsAll(<String>['a=1', 'b=2']),
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('请求编辑器 · 保存', () {
    testWidgets('保存写入精确字段，且保存后离开不再二次确认', (tester) async {
      final facade = _facade();
      final collection = facade.store.addCollection(name: 'API');

      await _pumpEditor(tester, facade: facade, collectionId: collection.id);

      await tester.enterText(find.byKey(const Key('request-editor-name')), '创建用户');
      await _setUrlViaSheet(tester, 'https://api.example/users');
      await tester.tap(find.byKey(const Key('request-editor-method')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('POST').last);
      await tester.pumpAndSettle();
      await _tapMore(tester, const Key('request-editor-save'));

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
      )!;

      await _pumpEditor(
        tester,
        facade: facade,
        request: request,
        collectionId: collection.id,
      );

      await _tapMore(tester, const Key('request-editor-save-as'));

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
      )!;

      await _pumpEditor(
        tester,
        facade: facade,
        request: request,
        collectionId: collection.id,
      );

      await _tapMore(tester, const Key('request-editor-export-curl'));

      expect(find.textContaining('curl'), findsWidgets);
      expect(find.textContaining('https://api.example/x'), findsWidgets);
      expect(tester.takeException(), isNull);
    });
  });

  group('请求编辑器 · 网络选项', () {
    testWidgets('弹层暴露 4 项；跳过 TLS 仅在危险确认后开启', (tester) async {
      final facade = _facade();
      final collection = facade.store.addCollection(name: 'API');

      await _pumpEditor(tester, facade: facade, collectionId: collection.id);
      await _openNetworkOptions(tester);

      expect(find.text('网络选项'), findsOneWidget);
      expect(
        find.byKey(const Key('request-editor-net-timeout')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('request-editor-net-follow')), findsOneWidget);
      expect(find.byKey(const Key('request-editor-net-jar')), findsOneWidget);
      expect(
        find.byKey(const Key('request-editor-net-skip-tls')),
        findsOneWidget,
      );

      // 危险开关默认关；点击后必须经统一确认弹层，且取消前不生效。
      expect(_switchValue(tester, 'request-editor-net-skip-tls'), isFalse);
      await tester.tap(find.byKey(const Key('request-editor-net-skip-tls')));
      await tester.pumpAndSettle();
      expect(find.text('跳过 TLS 证书校验？'), findsOneWidget);
      expect(
        _switchValue(tester, 'request-editor-net-skip-tls'),
        isFalse,
        reason: '确认前不得开启危险的跳过校验',
      );

      // 取消 → 保持严格。
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(
        _switchValue(tester, 'request-editor-net-skip-tls'),
        isFalse,
        reason: '取消确认必须保持严格证书',
      );

      // 再来一次并确认 → 只在确认后开启。
      await tester.tap(find.byKey(const Key('request-editor-net-skip-tls')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('仍要跳过'));
      await tester.pumpAndSettle();
      expect(_switchValue(tester, 'request-editor-net-skip-tls'), isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('保存后网络选项随模型持久化并可回读', (tester) async {
      final facade = _facade();
      final collection = facade.store.addCollection(name: 'API');

      await _pumpEditor(tester, facade: facade, collectionId: collection.id);
      await _openNetworkOptions(tester);

      await tester.enterText(
        find.byKey(const Key('request-editor-net-timeout')),
        '1500',
      );
      await tester.tap(find.byKey(const Key('request-editor-net-follow')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('request-editor-net-jar')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('request-editor-net-skip-tls')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('仍要跳过'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('request-editor-net-confirm')));
      await tester.pumpAndSettle();
      await _tapMore(tester, const Key('request-editor-save'));

      final saved = facade.store.collectionById(collection.id)!.requests.single;
      expect(saved.timeoutMs, 1500);
      expect(saved.followRedirects, isFalse);
      expect(saved.useCookieJar, isFalse);
      expect(saved.skipTlsVerify, isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('发送时把网络选项透传给 sender', (tester) async {
      final sender = _sender();
      final facade = _facade(sender: sender);
      final collection = facade.store.addCollection(name: 'API');
      final request = facade.store.addRequest(
        collection.id,
        DebugRequest(
          id: 'r-net',
          name: 'net',
          method: 'GET',
          url: 'https://api.example/x',
          timeoutMs: 1500,
          followRedirects: false,
          useCookieJar: false,
          skipTlsVerify: true,
        ),
      )!;

      await _pumpEditor(
        tester,
        facade: facade,
        request: request,
        collectionId: collection.id,
      );
      await tester.tap(find.byKey(const Key('request-editor-send')));
      await tester.pumpAndSettle();

      expect(sender.calls, hasLength(1));
      expect(sender.calls.single['timeoutMs'], 1500);
      expect(sender.calls.single['followRedirects'], isFalse);
      expect(sender.calls.single['useCookies'], isFalse);
      expect(sender.calls.single['skipTlsVerify'], isTrue);
      expect(tester.takeException(), isNull);
    });
  });

  group('请求编辑器 · 取消', () {
    testWidgets('发送中显示取消入口；取消后回到就绪且不追加历史', (tester) async {
      final sender = _sender()..blockUntilCancelled = true;
      final facade = _facade(sender: sender);
      final collection = facade.store.addCollection(name: 'API');
      final request = facade.store.addRequest(
        collection.id,
        DebugRequest(
          id: 'r-cancel',
          name: 'cancel',
          method: 'GET',
          url: 'https://api.example/slow',
        ),
      )!;

      await _pumpEditor(
        tester,
        facade: facade,
        request: request,
        collectionId: collection.id,
      );

      await tester.tap(find.byKey(const Key('request-editor-send')));
      await tester.pump();

      // 发送中：出现取消入口，发送按钮禁用。
      expect(find.byKey(const Key('request-editor-cancel')), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('request-editor-send')))
            .onPressed,
        isNull,
      );

      // 取消 → 回到就绪。
      await tester.tap(find.byKey(const Key('request-editor-cancel')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('request-editor-cancel')), findsNothing);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('request-editor-send')))
            .onPressed,
        isNotNull,
      );
      expect(find.text('尚未发送请求'), findsOneWidget,
          reason: '取消后必须回到就绪态，不展示残缺响应');
      expect(facade.store.history, isEmpty,
          reason: '取消绝不能追加半成品历史');
      expect(tester.takeException(), isNull);
    });

    testWidgets('重复取消幂等：无异常、无重复副作用', (tester) async {
      final sender = _sender()..blockUntilCancelled = true;
      final facade = _facade(sender: sender);
      final collection = facade.store.addCollection(name: 'API');

      await _pumpEditor(tester, facade: facade, collectionId: collection.id);
      await tester.tap(find.byKey(const Key('request-editor-send')));
      await tester.pump();
      expect(find.byKey(const Key('request-editor-cancel')), findsOneWidget);

      // 同一帧内连点两次取消（第二次命中已取消 token）。
      await tester.tap(find.byKey(const Key('request-editor-cancel')));
      await tester.tap(find.byKey(const Key('request-editor-cancel')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('request-editor-cancel')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('发送中返回：先警告；确认后取消请求并离开', (tester) async {
      final sender = _sender()..blockUntilCancelled = true;
      final facade = _facade(sender: sender);
      final collection = facade.store.addCollection(name: 'API');

      await _pumpEditor(tester, facade: facade, collectionId: collection.id);
      await tester.tap(find.byKey(const Key('request-editor-send')));
      await tester.pump();

      // 发送中返回 → 警告弹层（发送中 AppLoading 持续动画，用固定帧推进）。
      await tester.tap(find.byKey(const Key('request-editor-back')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('请求正在发送'), findsOneWidget,
          reason: '_sending 时必须警告而不能静默离开');

      // 继续等待 → 不离开。
      await tester.tap(find.text('继续等待'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const Key('request-editor-url')), findsOneWidget);

      // 再次返回并确认 → 取消请求并离开。
      await tester.tap(find.byKey(const Key('request-editor-back')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('取消请求并离开'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byKey(const Key('open-editor')), findsOneWidget);
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
      )!;

      await _pumpEditor(
        tester,
        facade: facade,
        request: request,
        collectionId: collection.id,
      );

      // 编辑 URL（自适应弹层提交）→ dirty。
      await _setUrlViaSheet(tester, 'https://api.example/new');

      // 返回 → 弹出二次确认。
      await tester.tap(find.byKey(const Key('request-editor-back')));
      await tester.pumpAndSettle();
      expect(find.text('放弃未保存的修改？'), findsOneWidget);

      // 选择「继续编辑」→ 不离开，编辑保留，未落盘。
      await tester.tap(find.text('继续编辑'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('open-editor')), findsNothing);
      expect(find.byKey(const Key('request-editor-url')), findsOneWidget);
      expect(_urlDisplay('https://api.example/new'), findsOneWidget);
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
      )!;

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
      // T12 起 URL 查询被规范化为参数行：提交不带查询的 URL 绝不丢弃既有参数，
      // 因此 `m={{missing}}` 仍保留并重新出现在显示 URL 上（不递归展开）。
      await _setUrlViaSheet(tester, '{{nested}}');
      expect(_previewText(tester), '{{host}}?m={{missing}}');
      expect(
        find.byKey(const Key('request-editor-env-missing-host')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('弹层内插入变量 → 命中弹层草稿（不写旧选区）', (tester) async {
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
      )!;

      await _pumpEditor(
        tester,
        facade: facade,
        request: request,
        collectionId: collection.id,
      );

      // 打开 URL 自适应弹层。
      await tester.tap(find.byKey(const Key('request-editor-url')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('request-editor-field-sheet')),
        findsOneWidget,
      );

      // 弹层内点「插入环境变量」→ 选择 → 落到弹层草稿。
      await tester.tap(find.byKey(const Key('request-editor-insert-var')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('request-editor-insert-var-host')),
      );
      await tester.pumpAndSettle();

      final draft = tester
          .widget<TextField>(find.byKey(const Key('request-editor-field-sheet-input')))
          .controller!;
      expect(
        draft.text,
        'https://api.example/{{host}}',
        reason: '插入必须命中弹层草稿，而非旧绑定值',
      );

      // 确认 → 写回字段并刷新预览。
      await tester.tap(find.byKey(const Key('request-editor-field-sheet-confirm')));
      await tester.pumpAndSettle();
      expect(_urlDisplay('https://api.example/{{host}}'), findsOneWidget);
      expect(_previewText(tester), 'https://api.example/https://api.example');
      expect(tester.takeException(), isNull);
    });

    testWidgets('AppSuggestionChips 含 store.history 派生的最近值', (tester) async {
      final facade = _facade();
      final collection = facade.store.addCollection(name: 'API');
      appendDebugHistory(
        facade,
        request: DebugRequest(
          id: 'r-hist',
          name: 'hist',
          method: 'GET',
          url: 'https://api.example/hist',
          headers: const <DebugHeader>[
            DebugHeader(name: 'X-Token', value: 'recent-secret-42'),
          ],
        ),
        response: const DebugResponse(statusCode: 200),
      );

      await _pumpEditor(tester, facade: facade, collectionId: collection.id);

      await tester.tap(find.byKey(const Key('request-editor-segment-headers')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('request-editor-headers-add')));
      await tester.pumpAndSettle();

      // 打开「值」自适应弹层，建议 chips 应含历史派生值。
      await tester.tap(find.byKey(const Key('request-editor-header-value-0')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('editor-suggestion-chip-recent-secret-42')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('工具栏 prev/next 在编辑器字段间移动焦点', (tester) async {
      final facade = _facade();
      final collection = facade.store.addCollection(name: 'API');
      final request = facade.store.addRequest(
        collection.id,
        DebugRequest(
          id: 'r-focus',
          name: 'focus',
          method: 'GET',
          url: 'https://api.example/',
          auth: const DebugAuth(
            type: DebugAuthType.basic,
            username: 'user',
            password: 'pass',
          ),
        ),
      )!;

      await _pumpEditor(
        tester,
        facade: facade,
        request: request,
        collectionId: collection.id,
      );

      // 切到认证段，使行内「用户名」字段存在。
      await tester.tap(find.byKey(const Key('request-editor-segment-auth')));
      await tester.pumpAndSettle();

      final authUserEditable = tester.widget<EditableText>(
        find.descendant(
          of: find.byKey(const Key('request-editor-auth-user')),
          matching: find.byType(EditableText),
        ),
      );
      expect(authUserEditable.focusNode.hasFocus, isFalse);

      // 打开 URL 弹层 → 工具栏「下一个」→ 焦点移到「用户名」。
      await tester.tap(find.byKey(const Key('request-editor-url')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('editor-toolbar-next')));
      await tester.pumpAndSettle();
      expect(
        authUserEditable.focusNode.hasFocus,
        isTrue,
        reason: 'next 应把焦点移向下一个字段',
      );

      // 再点「上一个」→ 焦点回到 URL 所在字段（弹层草稿）。
      await tester.tap(find.byKey(const Key('editor-toolbar-prev')));
      await tester.pumpAndSettle();
      expect(
        authUserEditable.focusNode.hasFocus,
        isFalse,
        reason: 'prev 应把焦点移回上一个字段',
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('请求编辑器 · 字段保真与脏标记', () {
    testWidgets('保存保留 overrides（_composeDraft 不丢失）', (tester) async {
      final facade = _facade();
      final collection = facade.store.addCollection(name: 'API');
      final request = facade.store.addRequest(
        collection.id,
        DebugRequest(
          id: 'r-overrides',
          name: 'ovr',
          method: 'GET',
          url: 'https://api.example/x',
          overrides: DebugResponseOverride(
            statusCode: 201,
            body: 'saved-override',
          ),
        ),
      )!;

      await _pumpEditor(
        tester,
        facade: facade,
        request: request,
        collectionId: collection.id,
      );

      await _tapMore(tester, const Key('request-editor-save'));

      final saved = facade.store.requestById('r-overrides')!;
      expect(saved.overrides, isNotNull,
          reason: 'overrides 必须在保存草稿时保留');
      expect(saved.overrides!.statusCode, 201);
      expect(saved.overrides!.body, 'saved-override');
      expect(tester.takeException(), isNull);
    });

    testWidgets('非标准 HTTP 方法（PROPFIND）保留并可保存', (tester) async {
      final facade = _facade();
      final collection = facade.store.addCollection(name: 'API');
      final request = facade.store.addRequest(
        collection.id,
        DebugRequest(
          id: 'r-custom-method',
          name: 'custom',
          method: 'PROPFIND',
          url: 'https://api.example/x',
        ),
      )!;

      await _pumpEditor(
        tester,
        facade: facade,
        request: request,
        collectionId: collection.id,
      );

      // 下拉当前值仍是自定义方法（未被回退成 GET）。
      expect(
        tester
            .widget<DropdownButton<String>>(
              find.byKey(const Key('request-editor-method')),
            )
            .value,
        'PROPFIND',
      );

      await _tapMore(tester, const Key('request-editor-save'));
      expect(facade.store.requestById('r-custom-method')!.method, 'PROPFIND');
      expect(tester.takeException(), isNull);
    });

    testWidgets('将认证改为 none 并保存 → 已存认证被清空', (tester) async {
      final facade = _facade();
      final collection = facade.store.addCollection(name: 'API');
      final request = facade.store.addRequest(
        collection.id,
        DebugRequest(
          id: 'r-auth-clear',
          name: 'auth',
          method: 'GET',
          url: 'https://api.example/x',
          auth: const DebugAuth(
            type: DebugAuthType.bearer,
            token: 'secret',
          ),
        ),
      )!;

      await _pumpEditor(
        tester,
        facade: facade,
        request: request,
        collectionId: collection.id,
      );

      await tester.tap(find.byKey(const Key('request-editor-segment-auth')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('request-editor-auth-type')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('none').last);
      await tester.pumpAndSettle();

      await _tapMore(tester, const Key('request-editor-save'));
      expect(facade.store.requestById('r-auth-clear')!.auth, isNull,
          reason: '切换为 none 后保存必须真正清空认证');
      expect(tester.takeException(), isNull);
    });

    testWidgets('body 工具栏清空后标记脏值：返回弹出未保存确认', (tester) async {
      final facade = _facade();
      final collection = facade.store.addCollection(name: 'API');
      final request = facade.store.addRequest(
        collection.id,
        DebugRequest(
          id: 'r-body-dirty',
          name: 'body',
          method: 'POST',
          url: 'https://api.example/x',
          body: 'hello',
          bodyKind: DebugBodyKind.text,
        ),
      )!;

      await _pumpEditor(
        tester,
        facade: facade,
        request: request,
        collectionId: collection.id,
      );

      await tester.tap(find.byKey(const Key('request-editor-segment-body')));
      await tester.pumpAndSettle();

      // 工具栏「清空」是程序化写 controller：若未绑定监听则不会标记脏值。
      await tester.tap(find.byKey(const Key('editor-toolbar-clear')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('request-editor-body')))
            .controller!
            .text,
        isEmpty,
      );

      // 返回 → 必须弹出未保存确认，证明清空已标记脏值。
      await tester.tap(find.byKey(const Key('request-editor-back')));
      await tester.pumpAndSettle();
      expect(find.text('放弃未保存的修改？'), findsOneWidget);
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

    testWidgets('窄屏 360x640：外壳渲染无异常且动作齐备', (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final facade = _facade();
      final collection = facade.store.addCollection(name: 'API');

      await _pumpEditor(tester, facade: facade, collectionId: collection.id);

      expect(find.byKey(const Key('request-editor-url')), findsOneWidget);
      expect(find.byKey(const Key('request-editor-send')), findsOneWidget);
      expect(find.byKey(const Key('request-editor-more')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
