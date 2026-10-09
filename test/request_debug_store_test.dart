import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:gstore/core/request_debug/debug_models.dart';
import 'package:gstore/core/request_debug/request_debug_store.dart';

/// 每个用例独立临时目录，模拟应用文档目录（可注入接缝）。
Directory _tempDir() =>
    Directory.systemTemp.createTempSync('request_debug_store_test_');

RequestDebugStore _storeFor(Directory dir, {int historyLimit = 200}) {
  return RequestDebugStore(
    directoryProvider: () async => dir,
    historyLimit: historyLimit,
  );
}

File _storeFile(Directory dir) =>
    File(p.join(dir.path, RequestDebugStore.fileName));

/// 一个「字段尽量填满」的请求，用于验证真实往返而不是「没有抛异常」。
DebugRequest _fullRequest({String id = 'req-1', String? collectionId}) {
  return DebugRequest(
    id: id,
    name: '创建用户',
    method: 'POST',
    url: 'https://api.example.com/users',
    headers: const [
      DebugHeader(name: 'Content-Type', value: 'application/json'),
      DebugHeader(name: 'X-Disabled', value: 'off', enabled: false),
    ],
    query: const [
      DebugQueryParam(name: 'page', value: '1'),
      DebugQueryParam(name: 'q', value: '张三 李四'),
    ],
    body: '{"name":"张三"}',
    bodyKind: DebugBodyKind.json,
    auth: const DebugAuth(
      type: DebugAuthType.bearer,
      token: 'token-abc',
    ),
    cookies: const [
      DebugCookie(name: 'sid', value: 'xyz', domain: 'example.com'),
    ],
    collectionId: collectionId,
    overrides: DebugResponseOverride(
      statusCode: 201,
      headers: const [DebugHeader(name: 'X-Override', value: 'yes')],
      body: '{"ok":true}',
    ),
  );
}

void main() {
  group('模型序列化往返（真实字段内容）', () {
    test('DebugRequest 全字段往返', () {
      final req = _fullRequest(collectionId: 'col-1');
      final restored = DebugRequest.fromJson(req.toJson());

      expect(restored.id, 'req-1');
      expect(restored.name, '创建用户');
      expect(restored.method, 'POST');
      expect(restored.url, 'https://api.example.com/users');
      expect(restored.body, '{"name":"张三"}');
      expect(restored.bodyKind, DebugBodyKind.json);
      expect(restored.collectionId, 'col-1');
      expect(restored.headers.length, 2);
      expect(restored.headers[0].name, 'Content-Type');
      expect(restored.headers[0].value, 'application/json');
      expect(restored.headers[0].enabled, true);
      expect(restored.headers[1].enabled, false);
      expect(restored.query.length, 2);
      expect(restored.query[1].name, 'q');
      expect(restored.query[1].value, '张三 李四');
      expect(restored.auth, isNotNull);
      expect(restored.auth!.type, DebugAuthType.bearer);
      expect(restored.auth!.token, 'token-abc');
      expect(restored.cookies.length, 1);
      expect(restored.cookies.first.name, 'sid');
      expect(restored.cookies.first.value, 'xyz');
      expect(restored.cookies.first.domain, 'example.com');
      expect(restored.overrides, isNotNull);
      expect(restored.overrides!.statusCode, 201);
      expect(restored.overrides!.headers!.single.name, 'X-Override');
      expect(restored.overrides!.body, '{"ok":true}');
    });

    test('DebugEnvironment 往返', () {
      final env = DebugEnvironment(
        id: 'env-1',
        name: '本地',
        vars: const {'host': 'localhost:8080', 'token': '空 格'},
      );
      final restored = DebugEnvironment.fromJson(env.toJson());
      expect(restored.id, 'env-1');
      expect(restored.name, '本地');
      expect(restored.vars['host'], 'localhost:8080');
      expect(restored.vars['token'], '空 格');
    });

    test('DebugRewriteRule 往返（镜像 CaptureRule UI 视图）', () {
      const rule = DebugRewriteRule(
        id: 'rule-1',
        enabled: true,
        method: 'GET',
        url: 'https://api.example.com/*',
        kind: DebugRewriteKind.replaceResponse,
        remark: 'mock 用户接口',
        statusCode: 200,
        respHeaders: [DebugHeader(name: 'Content-Type', value: 'application/json')],
        respBody: '{"mocked":true}',
        hitCount: 7,
      );
      final restored = DebugRewriteRule.fromJson(rule.toJson());
      expect(restored.id, 'rule-1');
      expect(restored.enabled, true);
      expect(restored.method, 'GET');
      expect(restored.url, 'https://api.example.com/*');
      expect(restored.kind, DebugRewriteKind.replaceResponse);
      expect(restored.remark, 'mock 用户接口');
      expect(restored.statusCode, 200);
      expect(restored.respHeaders!.single.value, 'application/json');
      expect(restored.respBody, '{"mocked":true}');
      expect(restored.hitCount, 7);
    });

    test('DebugHistoryEntry 往返', () {
      final entry = DebugHistoryEntry(
        id: 'h-1',
        tsMs: 1710000000000,
        request: _fullRequest(),
        responseSummary: const DebugResponseSummary(
          statusCode: 200,
          durationMs: 42,
          sizeBytes: 128,
          error: null,
        ),
      );
      final restored = DebugHistoryEntry.fromJson(entry.toJson());
      expect(restored.id, 'h-1');
      expect(restored.tsMs, 1710000000000);
      expect(restored.request.url, 'https://api.example.com/users');
      expect(restored.responseSummary.statusCode, 200);
      expect(restored.responseSummary.durationMs, 42);
      expect(restored.responseSummary.sizeBytes, 128);
    });

    test('枚举 fromWire 未知值安全降级', () {
      expect(DebugBodyKind.fromWire('nope'), DebugBodyKind.none);
      expect(DebugRewriteKind.fromWire(null), DebugRewriteKind.replaceResponse);
      expect(DebugAuthType.fromWire('weird'), DebugAuthType.none);
    });
  });

  group('存储 CRUD 往返（落盘 → 新实例重新加载）', () {
    test('集合 / 请求 / 环境 / 历史 / 规则完整往返', () async {
      final dir = _tempDir();
      addTearDown(() => dir.deleteSync(recursive: true));

      final store = _storeFor(dir);
      final folder = store.addCollection(name: '用户模块');
      final leaf = store.addCollection(name: '列表', parentId: folder.id);
      store.addRequest(leaf.id, _fullRequest(collectionId: leaf.id))!;
      store.addEnvironment(
        id: 'env-1',
        name: '本地',
        vars: const {'host': 'localhost'},
      );
      store.setActiveEnvironment('env-1');
      store.addHistory(DebugHistoryEntry(
        id: 'h-1',
        tsMs: 1710000000000,
        request: _fullRequest(),
        responseSummary: const DebugResponseSummary(statusCode: 200, durationMs: 5),
      ));
      store.addRule(const DebugRewriteRule(
        id: 'rule-1',
        url: 'https://api.example.com/*',
        kind: DebugRewriteKind.localResponse,
        statusCode: 503,
        respBody: 'down',
      ));

      expect(await store.save(), true);

      final reloaded = _storeFor(dir);
      await reloaded.load();

      expect(reloaded.collections.length, 2);
      final reloadedFolder =
          reloaded.collections.firstWhere((c) => c.id == folder.id);
      expect(reloadedFolder.name, '用户模块');
      expect(reloadedFolder.parentId, isNull);
      final reloadedLeaf =
          reloaded.collections.firstWhere((c) => c.id == leaf.id);
      expect(reloadedLeaf.name, '列表');
      expect(reloadedLeaf.parentId, folder.id);

      expect(reloadedLeaf.requests.length, 1);
      final req = reloadedLeaf.requests.single;
      expect(req.id, 'req-1');
      expect(req.method, 'POST');
      expect(req.url, 'https://api.example.com/users');
      expect(req.body, '{"name":"张三"}');
      expect(req.bodyKind, DebugBodyKind.json);
      expect(req.collectionId, leaf.id);
      expect(req.headers[1].enabled, false);
      expect(req.auth!.token, 'token-abc');
      expect(req.cookies.single.domain, 'example.com');

      expect(reloaded.requestById('req-1')?.name, '创建用户');

      expect(reloaded.environments.single.name, '本地');
      expect(reloaded.environments.single.vars['host'], 'localhost');
      expect(reloaded.activeEnvironmentId, 'env-1');

      expect(reloaded.history.single.request.url, 'https://api.example.com/users');
      expect(reloaded.history.single.responseSummary.statusCode, 200);

      expect(reloaded.rules.single.kind, DebugRewriteKind.localResponse);
      expect(reloaded.rules.single.statusCode, 503);
      expect(reloaded.rules.single.respBody, 'down');
      expect(reloaded.rules.single.enabled, false, reason: '规则默认关');
    });

    test('更新与删除生效并持久化', () async {
      final dir = _tempDir();
      addTearDown(() => dir.deleteSync(recursive: true));

      final store = _storeFor(dir);
      final col = store.addCollection(name: 'A');
      final req = store.addRequest(col.id, _fullRequest(id: 'r1'))!;
      store.updateRequest(req.copyWith(name: '改名后'));
      // 删除父集合应连带删除子集合与其请求
      final child = store.addCollection(name: '子', parentId: col.id);
      store.addRequest(child.id, _fullRequest(id: 'r2'))!;
      expect(store.removeCollection(col.id), true);
      expect(store.collectionById(col.id), isNull);
      expect(store.collectionById(child.id), isNull);
      expect(store.requestById('r1'), isNull);
      expect(store.requestById('r2'), isNull);

      // 环境删除
      store.addEnvironment(id: 'e1', name: 'E');
      expect(store.removeEnvironment('e1'), true);
      expect(store.environments, isEmpty);

      await store.save();
      final reloaded = _storeFor(dir);
      await reloaded.load();
      expect(reloaded.collections, isEmpty);
      expect(reloaded.requestById('r1'), isNull);
      expect(reloaded.environments, isEmpty);
    });
  });

  group('原子写（tmp + rename，失败不留半成品）', () {
    test('写入成功后可读且内容正确', () async {
      final dir = _tempDir();
      addTearDown(() => dir.deleteSync(recursive: true));

      final store = _storeFor(dir);
      store.addCollection(name: '第一版');
      expect(await store.save(), true);

      final raw = await _storeFile(dir).readAsString();
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      expect((decoded['collections'] as List).length, 1);
      // tmp 文件不残留
      expect(File('${_storeFile(dir).path}.tmp').existsSync(), false);
    });

    test('tmp 写入失败 → 返回 false，原文件保持上一版完整内容', () async {
      final dir = _tempDir();
      addTearDown(() => dir.deleteSync(recursive: true));

      final store = _storeFor(dir);
      store.addCollection(name: '第一版');
      expect(await store.save(), true);

      // 用一个同名目录占据 tmp 路径，令 writeAsString 失败（模拟写中断）。
      final tmpDir = Directory('${_storeFile(dir).path}.tmp');
      tmpDir.createSync();

      store.collections.clear();
      store.addCollection(name: '第二版');
      expect(await store.save(), false, reason: '写失败必须返回 false，不抛');

      // 目标文件必须仍是「第一版」而不是半截的「第二版」。
      final reloaded = _storeFor(dir);
      await reloaded.load();
      expect(reloaded.collections.length, 1);
      expect(reloaded.collections.single.name, '第一版');

      tmpDir.deleteSync(recursive: true);
      expect(await store.save(), true);
      final after = _storeFor(dir);
      await after.load();
      expect(after.collections.single.name, '第二版');
    });
  });

  group('损坏 / 脏状态降级（不抛，返回空或跳过脏条目）', () {
    test('非法 JSON → 空 store 且不抛', () async {
      final dir = _tempDir();
      addTearDown(() => dir.deleteSync(recursive: true));
      await _storeFile(dir).writeAsString('{ this is not json ');

      final store = _storeFor(dir);
      await store.load();
      expect(store.collections, isEmpty);
      expect(store.environments, isEmpty);
      expect(store.history, isEmpty);
      expect(store.rules, isEmpty);
    });

    test('合法 JSON 但根类型错误（数组）→ 空 store', () async {
      final dir = _tempDir();
      addTearDown(() => dir.deleteSync(recursive: true));
      await _storeFile(dir).writeAsString('[1,2,3]');

      final store = _storeFor(dir);
      await store.load();
      expect(store.collections, isEmpty);
    });

    test('根合法但个别脏条目被跳过，好的条目保留', () async {
      final dir = _tempDir();
      addTearDown(() => dir.deleteSync(recursive: true));
      final payload = {
        'version': 1,
        'collections': [
          {'id': 'c1', 'name': '好集合', 'requests': []},
          'this-is-not-an-object',
        ],
        'history': [
          {
            'id': 'h1',
            'tsMs': 1,
            'request': _fullRequest().toJson(),
            'responseSummary': {'statusCode': 200},
          },
          {'id': 'h-broken'}, // 缺 request / tsMs
        ],
        'environments': [
          {'id': 'e1', 'name': 'E', 'vars': {'k': 'v'}},
        ],
        'rules': 'not-a-list',
      };
      await _storeFile(dir).writeAsString(jsonEncode(payload));

      final store = _storeFor(dir);
      await store.load();
      expect(store.collections.length, 1);
      expect(store.collections.single.name, '好集合');
      expect(store.environments.single.vars['k'], 'v');
      expect(store.rules, isEmpty);
      // 历史：好的保留，缺字段的被跳过（不为空即证明是逐条容错）
      expect(store.history.any((h) => h.id == 'h1'), true);
      expect(store.history.any((h) => h.id == 'h-broken'), false);
    });

    test('文件不存在 → 空 store 不抛', () async {
      final dir = _tempDir();
      addTearDown(() => dir.deleteSync(recursive: true));
      final store = _storeFor(dir);
      await store.load();
      expect(store.collections, isEmpty);
    });
  });

  group('历史有界（最旧淘汰）', () {
    DebugHistoryEntry entry(String id) => DebugHistoryEntry(
          id: id,
          tsMs: int.parse(id),
          request: _fullRequest(id: 'req-$id'),
          responseSummary: const DebugResponseSummary(statusCode: 200),
        );

    test('超出上限时淘汰最旧，保留最新 N 条', () async {
      final dir = _tempDir();
      addTearDown(() => dir.deleteSync(recursive: true));
      final store = _storeFor(dir, historyLimit: 3);

      for (var i = 1; i <= 6; i++) {
        store.addHistory(entry('$i'));
      }
      expect(store.history.length, 3);
      // 最新在前，最旧（1/2/3）被淘汰
      expect(store.history.map((h) => h.id).toList(), ['6', '5', '4']);

      await store.save();
      final reloaded = _storeFor(dir, historyLimit: 3);
      await reloaded.load();
      expect(reloaded.history.length, 3);
      expect(reloaded.history.first.id, '6');
    });

    test('加载时对超限历史再次裁剪（旧文件超限也要有界）', () async {
      final dir = _tempDir();
      addTearDown(() => dir.deleteSync(recursive: true));
      final payload = {
        'version': 1,
        'collections': [],
        'environments': [],
        'rules': [],
        'history': [for (var i = 1; i <= 10; i++) entry('$i').toJson()],
      };
      await _storeFile(dir).writeAsString(jsonEncode(payload));

      final store = _storeFor(dir, historyLimit: 4);
      await store.load();
      expect(store.history.length, 4);
    });

    test('上限为 0 时历史恒为空', () async {
      final dir = _tempDir();
      addTearDown(() => dir.deleteSync(recursive: true));
      final store = _storeFor(dir, historyLimit: 0);
      store.addHistory(entry('1'));
      store.addHistory(entry('2'));
      expect(store.history, isEmpty);
    });
  });
}
