/// 「请求调试」store 硬化（plan todo 10）测试。
///
/// 覆盖验收标准（TDD 失败先行，见 `.omo/evidence/task-10-...md`）：
/// - **单飞保存**：并发 `save()` 合并为一次最终落盘，文件不损坏且为最新状态；
/// - **版本迁移**：合法 v1 → v2（数据保留、迁移前备份存在、磁盘 version 变为 2）；
///   部分损坏 v1（坏条目隔离，其余保留）；未知未来版本 → 只读降级、不抹除、
///   不重写、拒绝降级保存；
/// - **逐项容错**：集合内单个损坏请求被隔离，其他请求仍加载；
/// - **未知集合**：`addRequest` 返回 `null`（失败，不静默成功）；
/// - **上限**：集合 / 请求 / 环境 / 规则超上限按「保留前 N、跳过其余」；
///   序列化超过体积上限 → 保存失败且不留半成品；
/// - **失败可见**：`save()` 失败经统一 `AppDialogs.showError` 提示。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/request_debug/debug_models.dart';
import 'package:gstore/core/request_debug/debug_sender.dart';
import 'package:gstore/core/request_debug/request_debug_facade.dart';
import 'package:gstore/core/request_debug/request_debug_store.dart';

Directory _tempDir([String prefix = 'request_debug_hardening_']) =>
    Directory.systemTemp.createTempSync(prefix);

File _storeFile(Directory dir) =>
    File(p.join(dir.path, RequestDebugStore.fileName));

RequestDebugStore _storeFor(
  Directory dir, {
  int? historyLimit,
  int? collectionLimit,
  int? requestLimit,
  int? environmentLimit,
  int? ruleLimit,
  int? maxFileBytes,
}) =>
    RequestDebugStore(
      directoryProvider: () async => dir,
      historyLimit: historyLimit ?? RequestDebugStore.defaultHistoryLimit,
      collectionLimit: collectionLimit ?? RequestDebugStore.defaultCollectionLimit,
      requestLimit: requestLimit ?? RequestDebugStore.defaultRequestLimit,
      environmentLimit:
          environmentLimit ?? RequestDebugStore.defaultEnvironmentLimit,
      ruleLimit: ruleLimit ?? RequestDebugStore.defaultRuleLimit,
      maxFileBytes: maxFileBytes ?? RequestDebugStore.defaultMaxFileBytes,
    );

Map<String, dynamic> _requestJson(String id, {String url = 'https://a'}) => {
      'id': id,
      'name': 'n-$id',
      'method': 'GET',
      'url': url,
      'headers': <Object>[],
      'query': <Object>[],
      'body': '',
      'bodyKind': 'none',
      'cookies': <Object>[],
    };

Map<String, dynamic> _v1Root({
  List<Object?>? collections,
  List<Object?>? environments,
  List<Object?>? history,
  List<Object?>? rules,
  Object? activeEnvironmentId,
}) =>
    {
      'version': 1,
      'activeEnvironmentId': activeEnvironmentId,
      'collections': collections ?? <Object>[],
      'environments': environments ?? <Object>[],
      'history': history ?? <Object>[],
      'rules': rules ?? <Object>[],
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('单飞保存（合并并发，最新胜出，不损坏）', () {
    test('并发 save() 全部 awaited 后文件完整且为最新状态', () async {
      final dir = _tempDir();
      addTearDown(() => dir.deleteSync(recursive: true));
      final store = _storeFor(dir);
      store.addCollection(name: 'c-init');

      final futures = <Future<bool>>[];
      for (var i = 0; i < 25; i++) {
        store.addCollection(name: 'c$i');
        futures.add(store.save());
      }
      final results = await Future.wait(futures);

      expect(results.every((r) => r), isTrue, reason: '并发 save 都必须成功');
      // 唯一 tmp 不残留
      expect(File('${_storeFile(dir).path}.tmp').existsSync(), isFalse);

      final reloaded = _storeFor(dir);
      await reloaded.load();
      expect(reloaded.collections.length, 26);
      expect(reloaded.collections.last.name, 'c24', reason: '最新状态必须落盘');
    });

    test('保存进行中再次 save → 合并，最终落盘包含期间最新修改', () async {
      final dir = _tempDir();
      addTearDown(() => dir.deleteSync(recursive: true));
      final store = _storeFor(dir);
      store.addCollection(name: 'a');

      final first = store.save();
      store.addCollection(name: 'b'); // 第一次保存进行中修改
      final second = store.save(); // 合并进同一次单飞
      expect(await first, isTrue);
      expect(await second, isTrue);

      final reloaded = _storeFor(dir);
      await reloaded.load();
      final names = reloaded.collections.map((c) => c.name).toList();
      expect(names, containsAll(<String>['a', 'b']));
    });
  });

  group('版本迁移 v1 → v2', () {
    test('合法 v1 → 迁移到 v2：数据保留、迁移前备份存在、磁盘 version=2', () async {
      final dir = _tempDir();
      addTearDown(() => dir.deleteSync(recursive: true));
      final raw = jsonEncode(_v1Root(
        activeEnvironmentId: 'e1',
        collections: [
          {
            'id': 'c1',
            'name': '旧集合',
            'requests': [_requestJson('r1')],
          },
        ],
        environments: [
          {
            'id': 'e1',
            'name': 'Env',
            'vars': {'k': 'v'},
          },
        ],
      ));
      await _storeFile(dir).writeAsString(raw);

      expect(RequestDebugStore.schemaVersion, 2, reason: '当前 schema 应升到 v2');

      final store = _storeFor(dir);
      await store.load();

      expect(store.collections.single.name, '旧集合');
      expect(store.collections.single.requests.single.id, 'r1');
      expect(store.environments.single.vars['k'], 'v');
      expect(store.activeEnvironmentId, 'e1');

      // 迁移前原始文件备份存在且内容 = 迁移前原文。
      final backup =
          File(RequestDebugStore.migrationBackupPath(_storeFile(dir).path, 1));
      expect(backup.existsSync(), isTrue, reason: '迁移前必须保留原始文件备份');
      expect(await backup.readAsString(), raw);

      // 迁移后磁盘 version = 2。
      final disk =
          jsonDecode(await _storeFile(dir).readAsString()) as Map<String, dynamic>;
      expect(disk['version'], 2);
    });

    test('部分损坏 v1 → 坏条目隔离，其余各类数据保留', () async {
      final dir = _tempDir();
      addTearDown(() => dir.deleteSync(recursive: true));
      await _storeFile(dir).writeAsString(jsonEncode(_v1Root(
        collections: [
          {
            'id': 'c-good',
            'name': '好集合',
            'requests': [
              _requestJson('r-good-1'),
              {'name': '缺 id 的坏请求'},
              'not-an-object',
              _requestJson('r-good-2'),
            ],
          },
          'not-an-object',
          {'name': '缺 id 的坏集合'},
        ],
        environments: [
          {
            'id': 'e-good',
            'name': 'E',
            'vars': {'k': 'v'},
          },
          {'name': '缺 id 的坏环境'},
        ],
        history: [
          {
            'id': 'h-good',
            'tsMs': 1,
            'request': _requestJson('hr1'),
            'responseSummary': {'statusCode': 200},
          },
          {'id': 'h-bad'}, // 缺 tsMs / request
        ],
        rules: [
          {
            'id': 'rule-good',
            'enabled': true,
            'url': 'https://a/*',
            'kind': 'localResponse',
            'statusCode': 503,
            'hitCount': 0,
          },
          {'url': '缺 id 的坏规则'},
        ],
      )));

      final store = _storeFor(dir);
      await store.load();

      expect(store.collections.length, 1, reason: '坏集合被隔离');
      final col = store.collections.single;
      expect(col.id, 'c-good');
      expect(
        col.requests.map((r) => r.id).toList(),
        ['r-good-1', 'r-good-2'],
        reason: '集合内坏请求被隔离，好请求保留',
      );
      expect(store.environments.single.id, 'e-good');
      expect(store.history.any((h) => h.id == 'h-good'), isTrue);
      expect(store.history.any((h) => h.id == 'h-bad'), isFalse);
      expect(store.rules.single.id, 'rule-good');
    });

    test('未知未来版本 v999 → 只读降级、不抹除、不重写、拒绝降级保存', () async {
      final dir = _tempDir();
      addTearDown(() => dir.deleteSync(recursive: true));
      final raw = jsonEncode({
        'version': 999,
        'collections': [
          {
            'id': 'c-future',
            'name': '未来数据',
            'requests': [_requestJson('r-future')],
          },
        ],
        'environments': <Object>[],
        'history': <Object>[],
        'rules': <Object>[],
        'futureOnlyField': {'keep': true},
      });
      await _storeFile(dir).writeAsString(raw);

      final store = _storeFor(dir);
      await store.load();

      // 降级：能读到的数据仍可读（不抹除用户数据）。
      expect(store.collections.single.name, '未来数据');
      expect(store.collections.single.requests.single.id, 'r-future');
      // 不迁移、不重写：磁盘原文逐字保留（含未知字段）。
      expect(await _storeFile(dir).readAsString(), raw);
      // 未迁移 → 无备份。
      final backup =
          File(RequestDebugStore.migrationBackupPath(_storeFile(dir).path, 999));
      expect(backup.existsSync(), isFalse);
      // 拒绝以旧 schema 覆盖未来数据。
      expect(await store.save(), isFalse);
      expect(await _storeFile(dir).readAsString(), raw);
    });

    test('version 字段缺失 / 非法 → 按 v1 处理并迁移', () async {
      final dir = _tempDir();
      addTearDown(() => dir.deleteSync(recursive: true));
      final root = _v1Root(collections: [
        {'id': 'c1', 'name': '无版本集合', 'requests': <Object>[]},
      ]);
      root.remove('version');
      await _storeFile(dir).writeAsString(jsonEncode(root));

      final store = _storeFor(dir);
      await store.load();
      expect(store.collections.single.name, '无版本集合');

      final disk =
          jsonDecode(await _storeFile(dir).readAsString()) as Map<String, dynamic>;
      expect(disk['version'], 2);
    });
  });

  group('上限与跳过', () {
    test('集合 / 环境 / 规则超上限 → 保留前 N、跳过其余', () async {
      final dir = _tempDir();
      addTearDown(() => dir.deleteSync(recursive: true));
      await _storeFile(dir).writeAsString(jsonEncode({
        'version': 2,
        'collections': [
          for (var i = 0; i < 5; i++)
            {'id': 'c$i', 'name': 'c$i', 'requests': <Object>[]},
        ],
        'environments': [
          for (var i = 0; i < 5; i++)
            {'id': 'e$i', 'name': 'e$i', 'vars': <String, Object>{}},
        ],
        'history': <Object>[],
        'rules': [
          for (var i = 0; i < 5; i++)
            {
              'id': 'r$i',
              'url': 'https://a/$i',
              'kind': 'localResponse',
              'hitCount': 0,
            },
        ],
      }));

      final store = _storeFor(
        dir,
        collectionLimit: 2,
        environmentLimit: 3,
        ruleLimit: 1,
      );
      await store.load();

      expect(store.collections.map((c) => c.id).toList(), ['c0', 'c1']);
      expect(store.environments.map((e) => e.id).toList(), ['e0', 'e1', 'e2']);
      expect(store.rules.map((r) => r.id).toList(), ['r0']);
    });

    test('请求总数超上限 → 跨集合保留前 N、跳过其余', () async {
      final dir = _tempDir();
      addTearDown(() => dir.deleteSync(recursive: true));
      await _storeFile(dir).writeAsString(jsonEncode({
        'version': 2,
        'collections': [
          {
            'id': 'c0',
            'name': 'c0',
            'requests': [_requestJson('r0a'), _requestJson('r0b')],
          },
          {
            'id': 'c1',
            'name': 'c1',
            'requests': [_requestJson('r1a'), _requestJson('r1b')],
          },
        ],
        'environments': <Object>[],
        'history': <Object>[],
        'rules': <Object>[],
      }));

      final store = _storeFor(dir, requestLimit: 3);
      await store.load();

      final ids = [
        for (final c in store.collections)
          for (final r in c.requests) r.id,
      ];
      expect(ids, ['r0a', 'r0b', 'r1a']);
    });

    test('序列化超过体积上限 → save 返回 false 且不留半成品', () async {
      final dir = _tempDir();
      addTearDown(() => dir.deleteSync(recursive: true));
      final store = _storeFor(dir, maxFileBytes: 64);
      store.addCollection(name: 'x' * 512);

      expect(await store.save(), isFalse);
      expect(_storeFile(dir).existsSync(), isFalse, reason: '不得写入半成品');
      expect(File('${_storeFile(dir).path}.tmp').existsSync(), isFalse);
    });
  });

  group('addRequest 未知集合返回失败（不静默）', () {
    test('未知集合 → 返回 null，且请求未落库', () {
      final store = _storeFor(Directory.systemTemp);
      final result = store.addRequest(
        'no-such-collection',
        DebugRequest(id: 'r-x', name: 'x'),
      );
      expect(result, isNull, reason: '未知集合必须返回失败而非静默成功');
      expect(store.requestById('r-x'), isNull);
    });

    test('已知集合 → 返回回填 collectionId 的请求', () {
      final store = _storeFor(Directory.systemTemp);
      final col = store.addCollection(name: 'c');
      final linked = store.addRequest(
        col.id,
        DebugRequest(id: 'r-y', name: 'y'),
      );
      expect(linked, isNotNull);
      expect(linked!.collectionId, col.id);
      expect(col.requests.single.id, 'r-y');
    });
  });

  group('失败可见（统一 AppDialogs.showError）', () {
    test('真实落盘失败 → 门面上报失败且返回 false', () async {
      // 用一个「普通文件」充当目录 → 目标路径不可写，save 必然失败。
      final blockerRoot = _tempDir('request_debug_hardening_blocker_');
      addTearDown(() => blockerRoot.deleteSync(recursive: true));
      final blocker = File(p.join(blockerRoot.path, 'not-a-dir'));
      await blocker.writeAsString('x');

      final store = RequestDebugStore(
        directoryProvider: () async => Directory(blocker.path),
      );
      final facade = _RecordingErrorFacade(store: store);

      expect(await facade.save(), isFalse);
      expect(facade.errors, hasLength(1));
      expect(facade.errors.single, contains('保存失败'));
    });

    testWidgets('默认上报经统一 AppDialogs.showError 显示提示', (tester) async {
      // 体积上限为 0 → 保存不做任何磁盘 I/O 即失败（避免 fake-async 下的真实 IO）。
      final store = RequestDebugStore(
        directoryProvider: () async => Directory.systemTemp,
        maxFileBytes: 0,
      );
      final facade = DefaultRequestDebugFacade(
        store: store,
        sender: DebugSender(),
      );

      await tester.pumpWidget(MaterialApp(
        scaffoldMessengerKey: AppDialogs.scaffoldMessengerKey,
        home: const Scaffold(body: SizedBox.shrink()),
      ));

      final ok = await tester.runAsync(() => facade.save());
      expect(ok, isFalse);
      await tester.pump();
      expect(find.textContaining('保存失败'), findsOneWidget);
    });
  });
}

/// 记录失败上报的门面（覆盖默认 AppDialogs 通道，便于纯单测断言）。
class _RecordingErrorFacade extends DefaultRequestDebugFacade {
  _RecordingErrorFacade({required super.store}) : super(sender: DebugSender());

  final List<String> errors = <String>[];

  @override
  void reportSaveError(String message) => errors.add(message);
}
