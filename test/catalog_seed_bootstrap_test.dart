/// `CatalogSeedBootstrap.ensure` 的 Dart 门禁测试。
///
/// 验证：
/// 1. 随包 seed 被写成 `<files_dir>/catalog_seed.db`（tmp + rename，无残留 .tmp）；
/// 2. `repoEnsureSeed(path: <seed>)` 恰好调用一次，`repoMaterialize()` 恰好一次；
/// 3. `repoEnsureSeed` 抛错被吞掉（不向上抛、不物化），绝不阻塞启动。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/catalog/catalog_facade.dart';
import 'package:gstore/core/catalog/catalog_seed_bootstrap.dart';
import 'package:gstore/core/rust/generated/bridge.dart' as rust;

/// 只实现版本仓库三方法；其余 catalog 接口由 noSuchMethod 兜底。
class _RecordingRepoBackend implements CatalogBackend {
  final List<String> ensureSeedPaths = <String>[];
  int materializeCalls = 0;
  Object? ensureSeedError;
  Object? materializeError;

  @override
  Future<rust.CatalogRepoStatus> repoStatus() async => _status();

  @override
  Future<rust.CatalogRepoStatus> repoEnsureSeed({required String path}) async {
    ensureSeedPaths.add(path);
    final error = ensureSeedError;
    if (error != null) throw error;
    return _status();
  }

  @override
  Future<rust.CatalogMaterializeResult> repoMaterialize() async {
    materializeCalls++;
    final error = materializeError;
    if (error != null) throw error;
    return const rust.CatalogMaterializeResult(
      materialized: true,
      version: '0.0.12',
      apps: 17,
      categories: 13,
    );
  }

  @override
  Future<rust.CatalogRepoDownload> repoDownload({required String url}) =>
      throw UnimplementedError('repoDownload not used');

  @override
  Future<rust.CatalogRepoStatus> repoSelect({required String version}) =>
      throw UnimplementedError('repoSelect not used');

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
      'unused CatalogBackend member: ${invocation.memberName}');
}

rust.CatalogRepoStatus _status() => const rust.CatalogRepoStatus(
      currentVersion: '0.0.12',
      currentFile: 'seed/abc.db',
      apps: 17,
      categories: 13,
      entries: <rust.CatalogRepoEntry>[],
    );

ByteData _seedBytes() => ByteData.sublistView(
      Uint8List.fromList(List<int>.generate(256, (i) => i & 0xff)),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('catalog_seed_bootstrap_');
    CatalogSeedBootstrap.assetLoader = (key) async {
      expect(key, CatalogSeedBootstrap.seedAssetKey);
      return _seedBytes();
    };
  });

  tearDown(() async {
    CatalogFacade.backendOverride = null;
    CatalogSeedBootstrap.resetForTest();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('ensure writes the seed then calls ensureSeed + materialize once',
      () async {
    final backend = _RecordingRepoBackend();
    CatalogFacade.backendOverride = backend;

    await CatalogSeedBootstrap.ensure(filesDir: tempDir.path);

    final seedPath = '${tempDir.path}/${CatalogSeedBootstrap.seedFileName}';
    expect(backend.ensureSeedPaths, <String>[seedPath],
        reason: 'repoEnsureSeed must run exactly once with the seed path');
    expect(backend.materializeCalls, 1,
        reason: 'repoMaterialize must run exactly once after ensureSeed');

    final seed = File(seedPath);
    expect(seed.existsSync(), isTrue, reason: 'seed must be written');
    expect(
      seed.readAsBytesSync(),
      _seedBytes().buffer.asUint8List(_seedBytes().offsetInBytes,
          _seedBytes().lengthInBytes),
      reason: 'written seed must match the bundled asset bytes',
    );
    expect(File('$seedPath.tmp').existsSync(), isFalse,
        reason: 'the temp file must be renamed away');
  });

  test('a repoEnsureSeed failure is swallowed and skips materialize', () async {
    final backend = _RecordingRepoBackend()
      ..ensureSeedError = StateError('invalid seed database');
    CatalogFacade.backendOverride = backend;

    await expectLater(
      CatalogSeedBootstrap.ensure(filesDir: tempDir.path),
      completes,
      reason: 'bootstrap failures must never block startup',
    );

    expect(backend.ensureSeedPaths, hasLength(1));
    expect(backend.materializeCalls, 0,
        reason: 'materialize must not run after ensureSeed fails');
  });
}
