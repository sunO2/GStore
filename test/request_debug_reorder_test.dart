/// 「请求调试」拖拽排序 / 移动 / 复制 / 删除确认（plan todo 17）测试。
///
/// 覆盖验收标准：
/// - 排序后重载保持新顺序（store 落盘 → 新实例重新加载）；
/// - 跨文件夹移动请求更新 `collectionId`；
/// - 删除请求前出现危险确认弹层（取消不删、确认才删）；
/// - 拖拽后编辑不抛（无 disposed-controller 异常）；
/// - 环境变量行可拖拽重排且顺序持久化。
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
import 'package:gstore/page/request_debug/collection_section.dart';
import 'package:gstore/page/request_debug/environment_section.dart';
import 'package:gstore/page/request_debug/request_debug_page.dart';

// ==================== 假实现 ====================

/// 假发送器：**不触碰网络**。
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
      const DebugResponse(statusCode: 200);

  @override
  void close() {}
}

/// 假改写规则端口：内存表。
class _FakeRulesPort implements CaptureRulesPort {
  List<DebugRewriteRule> rules = <DebugRewriteRule>[];

  @override
  Future<List<DebugRewriteRule>> getRules() async =>
      List<DebugRewriteRule>.of(rules);

  @override
  Future<DebugRewriteRule> setRule(DebugRewriteRule rule) async => rule;

  @override
  Future<bool> removeRule(String id) async => false;
}

/// 测试门面：真实内存 store（不落盘）+ 假 sender / 规则端口。
class _RecordingFacade extends DefaultRequestDebugFacade {
  _RecordingFacade({
    required super.store,
    required super.sender,
    required super.captureRules,
  });

  @override
  Future<void> load() async {}

  @override
  Future<bool> save() async => true;
}

RequestDebugStore _memoryStore() =>
    RequestDebugStore(directoryProvider: () async => Directory.systemTemp);

_RecordingFacade _facade() => _RecordingFacade(
      store: _memoryStore(),
      sender: _FakeSender(),
      captureRules: _FakeRulesPort(),
    );

/// 与生产相同的全局通道，使底部弹层 / Snackbar 可真实呈现。
Widget _host(Widget child) => MaterialApp(
      navigatorKey: appNavigatorKey,
      scaffoldMessengerKey: AppDialogs.scaffoldMessengerKey,
      home: Scaffold(body: child),
    );

/// 打开导航头「更多」菜单并点选其中一项（排序 / 导入 cURL / …，Wave 8）。
Future<void> _tapCollectionMore(WidgetTester tester, Key itemKey) async {
  await tester.tap(find.byKey(const Key('request-debug-collection-transfer')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(itemKey));
  await tester.pumpAndSettle();
}

DebugRequest _request(String id, {String name = '', String url = ''}) =>
    DebugRequest(id: id, name: name, url: url);

// 真实落盘 store（用于顺序持久化断言）。
Directory _tempDir() =>
    Directory.systemTemp.createTempSync('request_debug_reorder_test_');

RequestDebugStore _diskStore(Directory dir) => RequestDebugStore(
      directoryProvider: () async => dir,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ==================== store：排序 / 移动 / 复制 ====================

  group('store 请求排序（持久化）', () {
    test('reorderRequest 后 reload 保持新顺序', () async {
      final dir = _tempDir();
      addTearDown(() => dir.deleteSync(recursive: true));

      final store = _diskStore(dir);
      final col = store.addCollection(id: 'c1', name: '集合');
      store.addRequest(col.id, _request('r1', name: 'A'));
      store.addRequest(col.id, _request('r2', name: 'B'));
      store.addRequest(col.id, _request('r3', name: 'C'));
      expect(await store.save(), true);

      // 把首项移到最后（onReorderItem 语义：newIndex 已按移除调整）。
      expect(store.reorderRequest('c1', 0, 2), true);
      expect(store.collectionById('c1')!.requests.map((r) => r.id),
          <String>['r2', 'r3', 'r1']);
      expect(await store.save(), true);

      final reloaded = _diskStore(dir);
      await reloaded.load();
      expect(reloaded.collectionById('c1')!.requests.map((r) => r.id),
          <String>['r2', 'r3', 'r1']);
    });

    test('reorderCollection 同级排序后 reload 保持新顺序', () async {
      final dir = _tempDir();
      addTearDown(() => dir.deleteSync(recursive: true));

      final store = _diskStore(dir);
      store.addCollection(id: 'a', name: 'A');
      final b = store.addCollection(id: 'b', name: 'B');
      store.addCollection(id: 'c', name: 'C');
      // 子文件夹同级排序也应持久化。
      store.addCollection(id: 'b1', name: 'B1', parentId: b.id);
      store.addCollection(id: 'b2', name: 'B2', parentId: b.id);
      expect(await store.save(), true);

      expect(store.reorderCollection(null, 0, 2), true);
      expect(store.reorderCollection('b', 0, 1), true);
      expect(
        store.collections.where((e) => e.parentId == null).map((e) => e.id),
        <String>['b', 'c', 'a'],
      );
      expect(
        store.collections.where((e) => e.parentId == 'b').map((e) => e.id),
        <String>['b2', 'b1'],
      );
      expect(await store.save(), true);

      final reloaded = _diskStore(dir);
      await reloaded.load();
      expect(
        reloaded.collections.where((e) => e.parentId == null).map((e) => e.id),
        <String>['b', 'c', 'a'],
      );
      expect(
        reloaded.collections.where((e) => e.parentId == 'b').map((e) => e.id),
        <String>['b2', 'b1'],
      );
    });
  });

  group('store 跨文件夹移动', () {
    test('moveRequest 更新 collectionId 并持久化', () async {
      final dir = _tempDir();
      addTearDown(() => dir.deleteSync(recursive: true));

      final store = _diskStore(dir);
      final c1 = store.addCollection(id: 'c1', name: '源');
      final c2 = store.addCollection(id: 'c2', name: '目标');
      store.addRequest(c1.id, _request('r1', name: 'A'));
      store.addRequest(c1.id, _request('r2', name: 'B'));
      store.addRequest(c2.id, _request('r0', name: 'Z'));
      expect(await store.save(), true);

      expect(store.moveRequest('r1', 'c2', index: 0), true);
      expect(store.collectionById('c1')!.requests.map((r) => r.id),
          <String>['r2']);
      expect(store.collectionById('c2')!.requests.map((r) => r.id),
          <String>['r1', 'r0']);
      expect(store.requestById('r1')!.collectionId, 'c2');
      expect(await store.save(), true);

      final reloaded = _diskStore(dir);
      await reloaded.load();
      final moved = reloaded.requestById('r1')!;
      expect(moved.collectionId, 'c2');
      expect(reloaded.collectionById('c2')!.requests.first.id, 'r1');
      expect(reloaded.collectionById('c1')!.requests.map((r) => r.id),
          <String>['r2']);
    });

    test('moveCollection 改父级；拒绝移入自身 / 后代（不产生环）', () {
      final store = _memoryStore();
      final root = store.addCollection(id: 'root', name: 'Root');
      final child = store.addCollection(id: 'child', name: 'Child', parentId: root.id);
      final other = store.addCollection(id: 'other', name: 'Other');

      // 自身 / 后代：拒绝。
      expect(store.moveCollection(root.id, root.id), false);
      expect(store.moveCollection(root.id, child.id), false);
      expect(store.collectionById('root')!.parentId, isNull);

      // 移动到兄弟顶层集合下：成功。
      expect(store.moveCollection(child.id, other.id), true);
      expect(store.collectionById('child')!.parentId, 'other');
      // 后代集合树仍完整，可被删除连带清理。
      expect(store.removeCollection('other'), true);
      expect(store.collectionById('child'), isNull);
    });
  });

  group('store 复制', () {
    test('duplicateRequest 新 id、插在原请求后、列表深拷贝', () {
      final store = _memoryStore();
      final col = store.addCollection(id: 'c1', name: '集合');
      store.addRequest(
        col.id,
        DebugRequest(
          id: 'r1',
          name: '原始',
          headers: const [DebugHeader(name: 'X', value: '1')],
          query: const [DebugQueryParam(name: 'q', value: 'v')],
        ),
      );

      final copy = store.duplicateRequest('r1');
      expect(copy, isNotNull);
      expect(copy!.id, isNot('r1'));
      expect(copy.name, '原始 副本');
      expect(copy.collectionId, 'c1');
      expect(store.collectionById('c1')!.requests.map((r) => r.id),
          <String>['r1', copy.id]);
      // 深拷贝：副本的列表与原请求不共享同一实例。
      final original = store.requestById('r1')!;
      expect(identical(copy.headers, original.headers), isFalse);
      expect(identical(copy.query, original.query), isFalse);
      copy.headers.add(const DebugHeader(name: 'Y', value: '2'));
      expect(original.headers.length, 1, reason: '改副本不影响原请求');
      expect(original.headers.first.value, '1');
    });

    test('duplicateCollection 递归复制子集合并重映射 id', () {
      final store = _memoryStore();
      final root = store.addCollection(id: 'root', name: 'Root');
      final child = store.addCollection(id: 'child', name: 'Child', parentId: root.id);
      store.addRequest(child.id, _request('r1', name: 'A'));
      store.addRequest(root.id, _request('r2', name: 'B'));

      final clone = store.duplicateCollection('root');
      expect(clone, isNotNull);
      expect(clone!.id, isNot('root'));
      expect(clone.parentId, isNull);
      expect(clone.name, 'Root 副本');
      // 新集合紧跟在原集合之后。
      expect(store.collections[store.collections.indexOf(
        store.collectionById('root')!,
      ) + 1].id, clone.id);

      // 后代被复制且 parentId 重映射到新副本。
      final clonedChild = store.collections.firstWhere(
        (c) => c.parentId == clone.id,
      );
      expect(clonedChild.id, isNot(child.id));
      expect(clonedChild.name, 'Child');
      expect(clonedChild.requests.single.name, 'A');
      expect(clonedChild.requests.single.collectionId, clonedChild.id);
      // 原集合不受影响。
      expect(store.collectionById('child')!.requests.single.id, 'r1');
    });
  });

  // ==================== widget：集合分区 ====================

  group('集合分区拖拽', () {
    testWidgets('拖拽请求手柄后 store 顺序变化，且不抛异常', (tester) async {
      final facade = _facade();
      final col = facade.store.addCollection(id: 'c1', name: '集合');
      facade.store.addRequest(col.id, _request('r1', name: '第一'));
      facade.store.addRequest(col.id, _request('r2', name: '第二'));
      facade.store.addRequest(col.id, _request('r3', name: '第三'));

      await tester.pumpWidget(_host(RequestDebugPage(facade: facade)));
      await tester.pumpAndSettle();

      // Wave 7：默认（排序关闭）不渲染拖拽手柄。
      final handle = find.byKey(const Key('request-debug-request-drag-r1'));
      expect(handle, findsNothing, reason: '排序关闭时不得显示请求拖拽手柄');
      expect(
        find.byKey(const Key('request-debug-collection-drag-c1')),
        findsNothing,
        reason: '排序关闭时不得显示集合拖拽手柄',
      );

      // Wave 8：排序切换已上移到导航头「更多」菜单，先开菜单再点「排序」。
      await _tapCollectionMore(
        tester,
        const Key('request-debug-collection-sort-toggle'),
      );
      expect(handle, findsOneWidget, reason: '开启排序后应显示请求拖拽手柄');
      expect(
        find.byKey(const Key('request-debug-collection-drag-c1')),
        findsOneWidget,
        reason: '开启排序后应显示集合拖拽手柄',
      );

      await tester.timedDrag(
        handle,
        const Offset(0, 160),
        const Duration(milliseconds: 400),
      );
      await tester.pumpAndSettle();

      final order =
          facade.store.collectionById('c1')!.requests.map((r) => r.id).toList();
      expect(order.first, isNot('r1'), reason: '拖拽后首项应变化');
      expect(order, contains('r1'));
      expect(tester.takeException(), isNull);
    });

    testWidgets('拖拽请求到另一文件夹更新 collectionId', (tester) async {
      final facade = _facade();
      final c1 = facade.store.addCollection(id: 'c1', name: '源');
      final c2 = facade.store.addCollection(id: 'c2', name: '目标');
      facade.store.addRequest(c1.id, _request('r1', name: '拖我'));

      await tester.pumpWidget(
        _host(RequestDebugCollectionSection(facade: facade)),
      );
      await tester.pumpAndSettle();

      final reqTile = find.byKey(const Key('request-debug-request-r1'));
      final target = find.byKey(Key('request-debug-collection-${c2.id}'));
      expect(reqTile, findsOneWidget);
      expect(target, findsOneWidget);

      final gesture = await tester.startGesture(tester.getCenter(reqTile));
      await tester.pump(const Duration(milliseconds: 600));
      await gesture.moveTo(tester.getCenter(target));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      // 单集合下 c2 的请求列表出现 r1，且 collectionId 更新。
      expect(facade.store.requestById('r1')!.collectionId, c2.id);
      expect(facade.store.collectionById('c2')!.requests.map((r) => r.id),
          <String>['r1']);
      expect(tester.takeException(), isNull);
    });

    testWidgets('拖拽后打开编辑器不抛 disposed-controller 异常', (tester) async {
      final facade = _facade();
      final col = facade.store.addCollection(id: 'c1', name: '集合');
      facade.store.addRequest(col.id, _request('r1', name: '第一', url: 'https://a'));
      facade.store.addRequest(col.id, _request('r2', name: '第二', url: 'https://b'));

      await tester.pumpWidget(_host(RequestDebugPage(facade: facade)));
      await tester.pumpAndSettle();

      // Wave 7/8：拖拽手柄仅在排序模式显示，排序切换在导航头「更多」菜单。
      await _tapCollectionMore(
        tester,
        const Key('request-debug-collection-sort-toggle'),
      );

      await tester.timedDrag(
        find.byKey(const Key('request-debug-request-drag-r1')),
        const Offset(0, 120),
        const Duration(milliseconds: 400),
      );
      await tester.pumpAndSettle();

      // 拖拽后点击请求进入编辑器，再返回：控制器不得已释放。
      await tester.tap(find.byKey(const Key('request-debug-request-r1')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('request-editor-name')), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.tap(find.byKey(const Key('request-editor-back')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('删除请求先弹危险确认：取消保留、确认删除', (tester) async {
      final facade = _facade();
      final col = facade.store.addCollection(id: 'c1', name: '集合');
      facade.store.addRequest(col.id, _request('r1', name: '要删的'));

      await tester.pumpWidget(
        _host(RequestDebugCollectionSection(facade: facade)),
      );
      await tester.pumpAndSettle();

      // 第一次：取消。
      await tester.tap(find.byKey(const Key('request-debug-request-menu-r1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('request-debug-request-delete-r1')));
      await tester.pumpAndSettle();
      expect(find.text('删除请求'), findsOneWidget, reason: '删除前必须有确认');
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(facade.store.requestById('r1'), isNotNull, reason: '取消不删除');

      // 第二次：确认。
      await tester.tap(find.byKey(const Key('request-debug-request-menu-r1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('request-debug-request-delete-r1')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      expect(facade.store.requestById('r1'), isNull, reason: '确认后删除');
      expect(tester.takeException(), isNull);
    });

    testWidgets('请求 / 集合复制菜单可生成副本', (tester) async {
      final facade = _facade();
      final col = facade.store.addCollection(id: 'c1', name: '集合');
      facade.store.addRequest(col.id, _request('r1', name: 'A'));

      await tester.pumpWidget(
        _host(RequestDebugCollectionSection(facade: facade)),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('request-debug-request-menu-r1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('request-debug-request-duplicate-r1')));
      await tester.pumpAndSettle();
      expect(facade.store.collectionById('c1')!.requests.length, 2);
      expect(tester.takeException(), isNull);

      await tester.tap(
        find.byKey(const Key('request-debug-collection-menu-c1')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('request-debug-collection-duplicate-c1')),
      );
      await tester.pumpAndSettle();
      expect(facade.store.collections.length, 2);
      expect(tester.takeException(), isNull);
    });
  });

  // ==================== widget：环境分区 ====================

  group('环境变量行拖拽', () {
    testWidgets('拖拽变量行后编辑并保存，顺序持久化且不抛', (tester) async {
      final dir = _tempDir();
      addTearDown(() => dir.deleteSync(recursive: true));
      final store = _diskStore(dir);
      store.addEnvironment(
        id: 'e1',
        name: '环境',
        vars: const {'a': '1', 'b': '2', 'c': '3'},
      );
      final facade = _RecordingFacade(
        store: store,
        sender: _FakeSender(),
        captureRules: _FakeRulesPort(),
      );

      await tester.pumpWidget(
        _host(RequestDebugEnvironmentSection(facade: facade)),
      );
      await tester.pumpAndSettle();

      // 打开编辑弹层。
      await tester.tap(find.byKey(const Key('request-debug-environment-e1')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('request-debug-env-name')), findsOneWidget);

      // 把第一行拖到最后。
      await tester.timedDrag(
        find.byKey(const Key('request-debug-env-drag-0')),
        const Offset(0, 200),
        const Duration(milliseconds: 400),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      // 拖拽后编辑仍然指向正确控制器（无 disposed-controller 异常）。
      await tester.enterText(
        find.byKey(const Key('request-debug-env-key-0')),
        'b',
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      await tester.tap(find.byKey(const Key('request-debug-env-save')));
      await tester.pumpAndSettle();

      // 顺序变为 b / c / a（首项被移到最后）。
      final vars = facade.store.environments.single.vars;
      expect(vars.keys.toList(), <String>['b', 'c', 'a']);

      // 真实磁盘读写须在 runAsync 中执行（testWidgets 的假时钟不驱动真实 IO）。
      await tester.runAsync(() async {
        expect(await store.save(), true);
        final reloaded = _diskStore(dir);
        await reloaded.load();
        expect(reloaded.environments.single.vars.keys.toList(),
            <String>['b', 'c', 'a']);
      });
      expect(tester.takeException(), isNull);
    });
  });
}
