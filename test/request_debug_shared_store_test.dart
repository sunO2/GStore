// Todo 8 tests：单一共享门面/store（消除双门面覆盖）。
//
// 覆盖验收：
// - 先经「抓包」路径保存、再经「UI」路径保存 → 两者变更都在磁盘保留
//   （两个独立 store 会因陈旧快照互相覆盖，产生丢更新）；
// - 请求调试页与抓包桥经共享 provider 取到**同一**门面 / store；
// - provider 提供显式 per-test 注入（[RequestDebugFacadeProvider.overrideFacade]）
//   与重置（[RequestDebugFacadeProvider.reset]），既有注入假实现的测试不受影响。
//
// 密闭式：真实内存 store（临时目录）+ 假 sender / 空规则端口，不触碰 FFI / 网络。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/request_debug/debug_models.dart';
import 'package:gstore/core/request_debug/debug_sender.dart';
import 'package:gstore/core/request_debug/request_debug_facade.dart';
import 'package:gstore/core/request_debug/request_debug_store.dart';
import 'package:gstore/core/rust/proxy/ProxyContract.dart';
import 'package:gstore/page/proxy/proxy_capture_debug_bridge.dart';
import 'package:gstore/page/request_debug/request_debug_facade_provider.dart';

/// 空规则端口（不触碰 FFI）。
class _EmptyRulesPort implements CaptureRulesPort {
  const _EmptyRulesPort();

  @override
  Future<List<DebugRewriteRule>> getRules() async =>
      const <DebugRewriteRule>[];

  @override
  Future<DebugRewriteRule> setRule(DebugRewriteRule rule) async => rule;

  @override
  Future<bool> removeRule(String id) async => false;
}

/// 抓包详情 fixture：一条 POST + JSON body（经生产映射可落库）。
CaptureDetail _detail() => CaptureDetail(
      recordId: 8,
      method: 'POST',
      scheme: 'https',
      host: 'api.example.com',
      url: 'https://api.example.com/login?x=1',
      reqHeaders: 'Content-Type: application/json',
      reqBody: utf8.encode('{"u":"1"}'),
      contentType: 'application/json',
    );

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('gstore-t8-shared-');
  });

  tearDown(() async {
    // 显式 per-test 重置：不把注入 / 单例泄漏给下一个测试。
    RequestDebugFacadeProvider.reset();
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  /// 新建一个绑定到临时目录的真实内存门面（假 sender / 空规则端口）。
  DefaultRequestDebugFacade facadeOn(Directory d) => DefaultRequestDebugFacade(
        store: RequestDebugStore(directoryProvider: () async => d),
        sender: DebugSender(),
        captureRules: const _EmptyRulesPort(),
      );

  /// 从磁盘重新加载（模拟下一次进程启动）。
  Future<RequestDebugStore> reload() async {
    final store = RequestDebugStore(directoryProvider: () async => dir);
    await store.load();
    return store;
  }

  group('反例：两个独立门面各持 store → 陈旧快照丢更新', () {
    test('抓包先保存、UI 从旧快照后保存 → 抓包写入被覆盖', () async {
      // UI 页面先打开（load 到空快照），随后抓包桥另起一个 store。
      final ui = facadeOn(dir);
      await ui.load();

      final capture = facadeOn(dir);
      await capture.load();
      final captureId =
          capture.store.addCollection(name: kCaptureDebugCollectionName).id;
      capture.store.addRequest(
        captureId,
        DebugRequest(id: 'cap-1', name: 'captured'),
      );
      expect(await capture.save(), isTrue);

      // UI 用尚未包含「抓包」集合的陈旧内存快照落盘。
      ui.store.addCollection(name: 'UI Requests');
      expect(await ui.save(), isTrue);

      final reloaded = await reload();
      expect(
        reloaded.collections.any((c) => c.name == kCaptureDebugCollectionName),
        isFalse,
        reason: '反例锁定：两个独立 store 时抓包变更被 UI 陈旧快照覆盖（丢更新）',
      );
    });
  });

  group('共享 provider：页面与抓包桥共用同一门面 / store', () {
    test('抓包桥默认门面 === provider.instance', () async {
      RequestDebugFacadeProvider.overrideFacade(facadeOn(dir));

      final bridge = RequestDebugCaptureBridge(); // 不注入 → 取共享 provider

      expect(
        identical(bridge.facade, RequestDebugFacadeProvider.instance),
        isTrue,
        reason: '抓包桥不得自建独立生产门面',
      );
    });

    test('抓包保存 + UI 编辑保存 → 两者变更都在磁盘保留（无丢更新）', () async {
      final shared = facadeOn(dir);
      RequestDebugFacadeProvider.overrideFacade(shared);

      // 抓包路径：默认经共享 provider。
      final bridge = RequestDebugCaptureBridge();
      await bridge.saveToCollection(_detail());

      // UI 路径：页面同样取共享 provider → 同一 store 实例，看到抓包变更。
      final ui = RequestDebugFacadeProvider.instance;
      expect(identical(ui, bridge.facade), isTrue, reason: '同一门面 / store');
      final uiCollection = ui.store.addCollection(name: 'UI Requests');
      ui.store.addRequest(
        uiCollection.id,
        DebugRequest(id: 'ui-1', name: 'edited in UI'),
      );
      expect(await ui.save(), isTrue);

      final reloaded = await reload();
      final captureCollection = reloaded.collections
          .firstWhere((c) => c.name == kCaptureDebugCollectionName);
      expect(captureCollection.requests, hasLength(1),
          reason: '抓包写入必须保留');
      expect(
        reloaded.collections.any((c) => c.name == 'UI Requests'),
        isTrue,
        reason: 'UI 写入必须保留',
      );
    });

    test('reset 清注入 → 再次注入使用新门面（per-test 隔离）', () async {
      final a = facadeOn(dir);
      RequestDebugFacadeProvider.overrideFacade(a);
      expect(identical(RequestDebugFacadeProvider.instance, a), isTrue);

      RequestDebugFacadeProvider.reset();
      final b = facadeOn(dir);
      RequestDebugFacadeProvider.overrideFacade(b);
      expect(identical(RequestDebugFacadeProvider.instance, b), isTrue);
      expect(identical(a, b), isFalse);
    });
  });
}
