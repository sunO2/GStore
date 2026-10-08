/// 「请求调试」窄门面（todo 29）测试：注入假实现，断言转发与模型值，
/// 并验证失败端口返回**显式错误结果**而非向上抛。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/request_debug/debug_cookie_jar.dart';
import 'package:gstore/core/request_debug/debug_models.dart';
import 'package:gstore/core/request_debug/debug_response.dart';
import 'package:gstore/core/request_debug/debug_sender.dart';
import 'package:gstore/core/request_debug/request_debug_facade.dart';
import 'package:gstore/core/request_debug/request_debug_store.dart';

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
    List<int>? bodyBytes,
    bool followRedirects = true,
    Duration? timeout,
    bool useCookies = true,
    bool skipTlsVerify = false,
  }) async {
    calls.add(<String, Object?>{
      'method': method,
      'url': url,
      'body': body,
      'headers': headers.length,
      'useCookies': useCookies,
    });
    return response;
  }

  @override
  void close() {}
}

/// 假改写规则端口：可返回模型，也可受控抛错以验证失败传播。
class _FakeRulesPort implements CaptureRulesPort {
  List<DebugRewriteRule> rules = <DebugRewriteRule>[];
  final List<DebugRewriteRule> setCalls = <DebugRewriteRule>[];
  final List<String> removeCalls = <String>[];
  bool shouldThrow = false;
  String throwMessage = 'port boom';

  @override
  Future<List<DebugRewriteRule>> getRules() async {
    if (shouldThrow) throw StateError(throwMessage);
    return rules;
  }

  @override
  Future<DebugRewriteRule> setRule(DebugRewriteRule rule) async {
    if (shouldThrow) throw StateError(throwMessage);
    setCalls.add(rule);
    return rule;
  }

  @override
  Future<bool> removeRule(String id) async {
    if (shouldThrow) throw StateError(throwMessage);
    removeCalls.add(id);
    return true;
  }
}

/// 内存 store（临时目录，永不落盘）：CRUD 走内存。
RequestDebugStore _memoryStore() =>
    RequestDebugStore(directoryProvider: () async => Directory.systemTemp);

DefaultRequestDebugFacade _facade({
  RequestDebugStore? store,
  DebugSender? sender,
  CaptureRulesPort? captureRules,
}) =>
    DefaultRequestDebugFacade(
      store: store ?? _memoryStore(),
      sender: sender ?? _FakeSender(),
      captureRules: captureRules ?? _FakeRulesPort(),
    );

void main() {
  test('saveCaptured 委托 store 并返回回填 collectionId 的请求模型', () async {
    final store = _memoryStore();
    final collection = store.addCollection(name: 'Captured');
    final facade = _facade(store: store);

    final saved = await facade.saveCaptured(
      collectionId: collection.id,
      request: DebugRequest(
        id: 'r-1',
        name: 'r-1',
        method: 'POST',
        url: 'https://a.example/x',
      ),
    );

    // 返回值是模型（id 保留、collectionId 被回填）。
    expect(saved.id, 'r-1');
    expect(saved.method, 'POST');
    expect(saved.collectionId, collection.id);

    // 真正写进了该集合。
    final inStore = store.collectionById(collection.id)!.requests;
    expect(inStore, hasLength(1));
    expect(inStore.single.id, 'r-1');
    expect(inStore.single.collectionId, collection.id);
  });

  test('send 委托 sender 并返回响应模型值', () async {
    final fake = _FakeSender()
      ..response = const DebugResponse(
        statusCode: 201,
        bodyText: 'created',
        sizeBytes: 7,
        durationMs: 12,
      );
    final facade = _facade(sender: fake);

    final response = await facade.send(
      method: 'PUT',
      url: 'https://a.example/y',
      body: 'hi',
    );

    expect(response.statusCode, 201);
    expect(response.bodyText, 'created');
    expect(response.sizeBytes, 7);
    expect(response.durationMs, 12);

    expect(fake.calls, hasLength(1));
    expect(fake.calls.single['method'], 'PUT');
    expect(fake.calls.single['url'], 'https://a.example/y');
    expect(fake.calls.single['body'], 'hi');
  });

  test('聚合 cURL / 环境替换纯函数（返回真实值）', () async {
    final facade = _facade();

    final parsed = facade.parseCurl('curl https://a.example/p?x=1');
    expect(parsed.isSuccess, isTrue);
    expect(parsed.request!.url, 'https://a.example/p?x=1');

    final exported = facade.toCurl(parsed.request!);
    expect(exported, contains('https://a.example/p?x=1'));
    expect(exported, contains('-X'));
    expect(exported, contains('GET'));

    final resolved = facade.resolveEnv(
      '{{host}}/v1',
      <String, String>{'host': 'https://api.example'},
    );
    expect(resolved.text, 'https://api.example/v1');
    expect(resolved.hasMissing, isFalse);

    final resolvedIn = facade.resolveEnvIn(
      '{{missing}}',
      DebugEnvironment(id: 'e1', name: 'e', vars: <String, String>{}),
    );
    expect(resolvedIn.text, '{{missing}}');
    expect(resolvedIn.missing, contains('missing'));
  });

  test('改写规则成功路径：返回模型且记录委托', () async {
    const rule = DebugRewriteRule(
      id: 'rule-1',
      enabled: true,
      method: 'GET',
      url: 'https://a.example/*',
      kind: DebugRewriteKind.replaceResponse,
      statusCode: 201,
    );
    final port = _FakeRulesPort()..rules = <DebugRewriteRule>[rule];
    final facade = _facade(captureRules: port);

    final list = await facade.getCaptureRules();
    expect(list.isSuccess, isTrue);
    expect(list.value, hasLength(1));
    expect(list.value!.single.id, 'rule-1');
    expect(list.value!.single.statusCode, 201);
    expect(list.value!.single.kind, DebugRewriteKind.replaceResponse);

    final setResult = await facade.setCaptureRule(rule);
    expect(setResult.isSuccess, isTrue);
    expect(setResult.value!.id, 'rule-1');
    expect(port.setCalls.single.id, 'rule-1');

    final removeResult = await facade.removeCaptureRule('rule-1');
    expect(removeResult.isSuccess, isTrue);
    expect(removeResult.value, isTrue);
    expect(port.removeCalls, <String>['rule-1']);
  });

  test('规则端口抛错 → 显式失败结果（门面不向上抛）', () async {
    final port = _FakeRulesPort()..shouldThrow = true;
    final facade = _facade(captureRules: port);

    final list = await facade.getCaptureRules();
    expect(list.isSuccess, isFalse);
    expect(list.value, isNull);
    expect(list.error, contains('port boom'));

    final setResult = await facade.setCaptureRule(
      const DebugRewriteRule(
        id: 'x',
        url: 'https://a.example/x',
        kind: DebugRewriteKind.replaceResponse,
      ),
    );
    expect(setResult.isSuccess, isFalse);
    expect(setResult.value, isNull);
    expect(setResult.error, contains('port boom'));

    final removeResult = await facade.removeCaptureRule('x');
    expect(removeResult.isSuccess, isFalse);
    expect(removeResult.error, contains('port boom'));
  });

  test('默认规则端口未接线 → 显式失败（迫使测试注入假实现）', () async {
    final facade = DefaultRequestDebugFacade(
      store: _memoryStore(),
      sender: _FakeSender(),
    );

    final result = await facade.getCaptureRules();
    expect(result.isSuccess, isFalse);
    expect(result.value, isNull);
    expect(result.error, contains('todo 35'));
    expect(facade.captureRules, isA<UnavailableCaptureRulesPort>());
  });

  test('生产组合工厂装配真实 store/sender 与未接线规则端口', () async {
    final facade = DefaultRequestDebugFacade.production(
      directoryProvider: () async => Directory.systemTemp,
    );

    expect(facade.store, isA<RequestDebugStore>());
    expect(facade.sender, isA<DebugSender>());
    expect(facade.captureRules, isA<UnavailableCaptureRulesPort>());
    facade.sender.close();
  });

  test('store 持久化失败 → save 返回 false（不抛）', () async {
    final facade = DefaultRequestDebugFacade(
      store: RequestDebugStore(
        directoryProvider: () async => throw StateError('no dir'),
      ),
      sender: _FakeSender(),
      captureRules: _FakeRulesPort(),
    );

    expect(await facade.save(), isFalse);
  });
}
