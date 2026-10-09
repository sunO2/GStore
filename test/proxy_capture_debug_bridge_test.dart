// Todo 35 tests：抓包动作桥**生产适配器**（映射 + 经门面落库）。
//
// 密闭式：注入真实内存 store（临时目录）与假 sender / 空规则端口，**不触碰
// FFI / 网络**。断言「保存到请求调试」把抓包详情映射为 DebugRequest 并写入
// 「抓包」集合；落盘失败 → 结构化异常（由 binder 边界转 showError）。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/request_debug/debug_models.dart';
import 'package:gstore/core/request_debug/debug_sender.dart';
import 'package:gstore/core/request_debug/request_debug_facade.dart';
import 'package:gstore/core/request_debug/request_debug_store.dart';
import 'package:gstore/core/rust/proxy/ProxyContract.dart';
import 'package:gstore/page/proxy/proxy_capture_bridge.dart';
import 'package:gstore/page/proxy/proxy_capture_debug_bridge.dart';

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

/// 门面：真实内存 store，但落盘受控失败。
class _FailingSaveFacade extends DefaultRequestDebugFacade {
  _FailingSaveFacade(RequestDebugStore store)
      : super(
          store: store,
          sender: DebugSender(),
          captureRules: const _EmptyRulesPort(),
        );

  @override
  Future<bool> save() async => false;
}

CaptureDetail _detail() => CaptureDetail(
      recordId: 7,
      method: 'POST',
      scheme: 'https',
      host: 'api.example.com',
      url: 'https://api.example.com/login?x=1',
      reqHeaders: 'Content-Type: application/json\r\nCookie: sid=xyz',
      reqBody: utf8.encode('{"u":"1"}'),
      contentType: 'application/json',
    );

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('gstore-t35-bridge-');
  });

  tearDown(() async {
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  DebugCollection captureCollection(RequestDebugStore store) =>
      store.collections
          .firstWhere((c) => c.name == kCaptureDebugCollectionName);

  RequestDebugFacade facadeFor(RequestDebugStore store) =>
      DefaultRequestDebugFacade(
        store: store,
        sender: DebugSender(),
        captureRules: const _EmptyRulesPort(),
      );

  test('saveToCollection：映射并写入「抓包」集合（可重发字段齐全）', () async {
    final store = RequestDebugStore(directoryProvider: () async => dir);
    final bridge = RequestDebugCaptureBridge(facade: facadeFor(store));

    await bridge.saveToCollection(_detail());

    final collection = captureCollection(store);
    expect(collection.requests, hasLength(1));
    final saved = collection.requests.single;
    expect(saved.method, 'POST');
    expect(saved.url, 'https://api.example.com/login?x=1');
    expect(saved.body, '{"u":"1"}');
    expect(saved.bodyKind, DebugBodyKind.json);
    expect(saved.collectionId, collection.id);
    expect(
      saved.headers.any((h) => h.name == 'Content-Type'),
      isTrue,
    );
    expect(saved.cookies.single.name, 'sid');

    // 再次保存复用同一集合，不重复创建（load 会重建对象，故重新取）。
    await bridge.saveToCollection(_detail());
    expect(
      store.collections.where((c) => c.name == kCaptureDebugCollectionName),
      hasLength(1),
    );
    expect(captureCollection(store).requests, hasLength(2));
  });

  test('落盘失败 → 结构化异常（binder 边界转 showError，不裸崩）', () async {
    final facade = _FailingSaveFacade(
      RequestDebugStore(directoryProvider: () async => dir),
    );
    final bridge = RequestDebugCaptureBridge(facade: facade);

    await expectLater(
      bridge.saveToCollection(_detail()),
      throwsA(isA<StateError>()),
    );
  });

  test('openRewriteRuleEditor：预填经注入 opener 透传（路由 extra 语义）', () async {
    final store = RequestDebugStore(directoryProvider: () async => dir);
    CaptureRulePrefill? opened;
    final bridge = RequestDebugCaptureBridge(
      facade: facadeFor(store),
      openRuleEditor: (prefill) => opened = prefill,
    );

    const prefill = CaptureRulePrefill(
      method: 'PUT',
      url: 'https://api.test/v2/item',
      replaceBody: '{"ok":true}',
      statusCode: 201,
      responseHeaders: 'X-Resp: 1',
    );
    await bridge.openRewriteRuleEditor(prefill);

    expect(opened, same(prefill));
  });
}
