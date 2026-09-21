// 回退到内置后的自举门「作废」回归：回退成功（删除/替换磁盘产物并挂载内置）后，
// `ModuleBootstrap` 必须停止服务回退前缓存的实例/状态，否则后续 `acquire` 会命中
// 陈旧实例、把回退掩盖到下次重启。
//
// 覆盖（纯 Dart，无 FFI/网络，全部经 debug 接缝注入）：
// 1. 控制器 `rollback` 成功 → `ModuleBootstrap.invalidate` 淘汰缓存实例/ready 状态，
//    后续 `acquire` 真正重新 ensure + 重建（新实例对象）；
// 2. `rollback` 返回 false → 绝不作废（缓存与 ready 原样保留）；
// 3. 在途 ensure 期间 `invalidate` → 晚到完成不得复活 ready/写回陈旧实例，
//    且绝不并发启动第二次安装；
// 4. 不变量：`invalidate` 后 `hasInstance == false` 且最后状态为 `absent`；
// 5. 无缓存模块上 `invalidate` 为无害 no-op。
//
// 另含 `RustModuleLoader.invalidateModule` 的代号墓碑测试：在途安装必须于写盘
// 检查点前自行中止（不强杀 future、不移除每模块单飞条目）。
//
// `file_names` 与 lib/core/rust 既有约定一致。
// ignore_for_file: file_names

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/rust/ModuleBootstrap.dart';
import 'package:gstore/core/rust/ModuleLoader.dart';
import 'package:gstore/core/rust/ModuleManifest.dart';
import 'package:gstore/core/rust/ModuleManifestClient.dart';
import 'package:gstore/core/rust/ModuleManager.dart' show RustModuleInstance;
import 'package:gstore/core/rust/generated/bridge.dart' show ModuleHandle;
import 'package:gstore/page/module_manage/logic.dart';
import 'package:path/path.dart' as p;

/// 伪造的宿主模块句柄（仅经 `loadOverride` 原样返回，不触碰 FFI）。
class _FakeHandle implements ModuleHandle {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 伪造的模块实例：记录 `dispose` 次数与身份 id，不触碰 FFI。
class _FakeInstance implements RustModuleInstance {
  _FakeInstance(this.id);

  final int id;
  int disposeCalls = 0;

  @override
  Future<void> dispose() async {
    disposeCalls++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 解析固定模块资产的假清单客户端（供 loader 真实安装路径测试）。
class _FakeManifestClient extends ModuleManifestClient {
  _FakeManifestClient({required this.manifest, required this.url});

  final ModuleManifestV2 manifest;
  final String url;

  @override
  Future<ModuleManifestV2?> load({bool forceRefresh = false}) async => manifest;

  @override
  Future<ModuleAssetLocation?> locateModuleAsset(
    String moduleName, {
    bool forceRefresh = false,
  }) async {
    final entry = manifest.entry(moduleName);
    if (entry == null) return null;
    final asset = entry.forAbi('arm64-v8a');
    if (asset == null) return null;
    return ModuleAssetLocation(
      url: url,
      asset: asset.asset,
      sha256: asset.sha256,
      size: asset.size,
      version: entry.version,
      abi: 'arm64-v8a',
    );
  }
}

/// 可保持（hold）的下载器：调用 `fetch` 时完成 [started]，随后等待 [gate]。
class _HeldFetcher implements ModuleFetcher {
  _HeldFetcher(this.gate, this.started);

  final Future<Uint8List?> gate;
  final Completer<void> started;
  int fetchCalls = 0;

  @override
  Future<Uint8List?> fetch(String url, {int? maxBytes}) {
    fetchCalls++;
    if (!started.isCompleted) started.complete();
    return gate;
  }
}

/// 单模块单 ABI 的 v2 清单（测试注入，零网络）。
Map<String, dynamic> _manifestQr() => <String, dynamic>{
      'version': 2,
      'modules': <String, dynamic>{
        'qr': <String, dynamic>{
          'version': '1.0.0',
          'abi': <String, dynamic>{
            'arm64-v8a': <String, dynamic>{
              'asset': 'libgstore_mod_qr_1.0.0-arm64-v8a.so',
              'sha256': sha256.convert(const <int>[1, 2, 3]).toString(),
              'size': 3,
            },
          },
        },
      },
    };

ModuleManifestV2 _loaderManifest(Uint8List bytes) => ModuleManifestV2.fromJson(
      <String, dynamic>{
        'version': 2,
        'modules': <String, dynamic>{
          'qr': <String, dynamic>{
            'version': '0.5.0',
            'abi': <String, dynamic>{
              'arm64-v8a': <String, dynamic>{
                'asset': 'libgstore_mod_qr_0.5.0-arm64-v8a.so',
                'sha256': sha256.convert(bytes).toString(),
                'size': bytes.length,
              },
            },
          },
        },
      },
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final bootstrap = ModuleBootstrap.instance;
  final loader = RustModuleLoader.instance;
  late Directory tmp;

  setUp(() async {
    bootstrap.debugReset();
    loader.debugReset();
    loader.requireSignature = false;
    loader.remoteBaseUrl = null;
    tmp = await Directory.systemTemp.createTemp('gstore_rollback_invalidate_');
  });

  tearDown(() async {
    bootstrap.debugReset();
    loader.debugReset();
    loader.requireSignature = false;
    loader.remoteBaseUrl = null;
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  /// 注入自举门接缝：ensure/factory 计数、假句柄、按序编号的假实例、零延迟退避。
  ({int Function() ensureCalls, int Function() factoryCalls, List<_FakeInstance> instances})
      configureBootstrap({Future<bool> Function(String)? ensure}) {
    var ensures = 0;
    var factories = 0;
    final instances = <_FakeInstance>[];
    bootstrap.debugConfigure(
      ensureOverride: (
        String module, {
        required bool allowDownload,
        ModuleProgressCallback? onProgress,
      }) {
        ensures++;
        if (ensure != null) return ensure(module);
        return Future<bool>.value(true);
      },
      loadOverride: (String module) async => _FakeHandle(),
      factoryOverride: (ModuleHandle handle) async {
        final instance = _FakeInstance(factories);
        factories++;
        instances.add(instance);
        return instance;
      },
      delayOverride: (Duration duration) async {},
    );
    return (
      ensureCalls: () => ensures,
      factoryCalls: () => factories,
      instances: instances,
    );
  }

  /// 注入 loader 接缝：清单/本地枚举/probe/回退覆写（控制器用）。
  void configureLoader({Future<bool> Function(String name)? rollback}) {
    loader.debugConfigure(
      installedNamesOverride: () async => const <String>[],
      manifestOverride: _manifestQr(),
      probeOverride: (String name) async =>
          RustModuleStatus(name: name, exists: false, source: 'none'),
      rollbackOverride: rollback,
    );
  }

  /// 读取控制器（经 ProviderContainer，纯 Dart，无 widget）。
  RustPluginsController controllerOf(ProviderContainer container) =>
      container.read(rustPluginsProvider.notifier);

  group('ModuleBootstrap.invalidate（回退成功后的作废）', () {
    test(
      '控制器 rollback 成功 → 作废缓存实例/ready，后续 acquire 真正重建',
      () async {
        final counters = configureBootstrap();
        final first = await bootstrap.acquire('qr');
        expect(bootstrap.hasInstance('qr'), isTrue);
        expect(bootstrap.debugInstanceCacheCount, 1);
        expect(counters.ensureCalls(), 1);
        expect(counters.factoryCalls(), 1);

        configureLoader(rollback: (_) async => true);
        final container = ProviderContainer();
        addTearDown(container.dispose);

        final ok = await controllerOf(container).rollback('qr');
        expect(ok, isTrue, reason: '注入的成功回退应返回 true');

        // 回退成功 → 自举门必须淘汰回退前世界。
        expect(bootstrap.debugInstanceCacheCount, 0,
            reason: '回退成功后必须淘汰回退前的缓存实例');
        expect(bootstrap.hasInstance('qr'), isFalse);
        expect(first, isA<_FakeInstance>());
        expect((first as _FakeInstance).disposeCalls, 1,
            reason: '淘汰实例应 best-effort 释放底层实例');

        final snapshot = await bootstrap.states.first;
        expect(
          snapshot.any((s) =>
              s.module == 'qr' && s.phase == ModuleBootstrapPhase.ready),
          isFalse,
          reason: '回退后该模块的可观测阶段不得仍为 ready',
        );

        // 后续 acquire 真正重新安装并创建**新**实例对象。
        final second = await bootstrap.acquire('qr');
        expect(counters.ensureCalls(), 2,
            reason: '回退后 acquire 不得复用陈旧实例，必须重新 ensure');
        expect(counters.factoryCalls(), 2,
            reason: '回退后 acquire 必须重新创建实例');
        expect(identical(first, second), isFalse, reason: '必须是新实例对象');
      },
    );

    test('控制器 rollback 返回 false → 绝不作废（缓存与 ready 原样保留）', () async {
      final counters = configureBootstrap();
      final first = await bootstrap.acquire('qr');
      expect(bootstrap.debugInstanceCacheCount, 1);

      configureLoader(rollback: (_) async => false);
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final ok = await controllerOf(container).rollback('qr');
      expect(ok, isFalse, reason: '非破坏性失败必须返回 false');

      expect(bootstrap.debugInstanceCacheCount, 1,
          reason: '回退失败绝不作废缓存实例');
      expect(bootstrap.hasInstance('qr'), isTrue);
      expect((first as _FakeInstance).disposeCalls, 0,
          reason: '回退失败绝不释放实例');

      final snapshot = await bootstrap.states.first;
      expect(
        snapshot
            .any((s) => s.module == 'qr' && s.phase == ModuleBootstrapPhase.ready),
        isTrue,
        reason: '回退失败后模块必须仍可观测为 ready',
      );

      // 后续 acquire 命中缓存：零新增 ensure/factory。
      await bootstrap.acquire('qr');
      expect(counters.ensureCalls(), 1);
      expect(counters.factoryCalls(), 1);
    });

    test('在途 ensure 期间 invalidate：晚到完成不复活 ready，且不并发安装', () async {
      final gate = Completer<bool>();
      var concurrent = 0;
      var maxConcurrent = 0;
      final counters = configureBootstrap(ensure: (module) {
        concurrent++;
        if (concurrent > maxConcurrent) maxConcurrent = concurrent;
        return gate.future.whenComplete(() => concurrent--);
      });

      final pending = bootstrap.acquire('qr');
      final pendingResult =
          pending.then<Object?>((value) => value, onError: (Object error) => error);
      await pumpEventQueue();
      expect(counters.ensureCalls(), 1, reason: '首次获取应发起一次 ensure');
      expect(concurrent, 1, reason: '一次 ensure 应真实在途');

      // 模拟回退成功后的作废：在途 ensure 的 future 保留（绝不强杀），但代次已变。
      bootstrap.invalidate('qr');
      expect(bootstrap.hasInstance('qr'), isFalse);

      // 晚到完成：其结果属于回退前世界，必须被丢弃。
      gate.complete(true);
      final result = await pendingResult;
      expect(result, isA<ModuleInstallFailedException>(),
          reason: '被作废的获取必须放弃，绝不返回陈旧实例');
      await pumpEventQueue();

      expect(bootstrap.debugInstanceCacheCount, 0,
          reason: '晚到完成不得写回实例缓存');
      expect(bootstrap.hasInstance('qr'), isFalse);
      final snapshot = await bootstrap.states.first;
      expect(
        snapshot
            .any((s) => s.module == 'qr' && s.phase == ModuleBootstrapPhase.ready),
        isFalse,
        reason: '晚到完成不得复活回退前的 ready 状态',
      );

      // 后续 acquire 必须能开启**全新**尝试并成功。
      final fresh = await bootstrap.acquire('qr');
      expect(fresh, isNotNull);
      expect(counters.ensureCalls(), 2,
          reason: '回退后后续 acquire 必须发起全新 ensure');
      expect(counters.factoryCalls(), 1, reason: '仅新尝试创建实例');
      expect(maxConcurrent, 1, reason: '绝不并发启动两次安装');
    });

    test('不变量：invalidate 后 hasInstance=false 且最后状态为 absent', () async {
      configureBootstrap();
      final states = <ModuleBootstrapState>[];
      final sub = bootstrap.watch('qr').listen(states.add);
      await pumpEventQueue();

      await bootstrap.acquire('qr');
      await pumpEventQueue();
      expect(states.last.phase, ModuleBootstrapPhase.ready);

      bootstrap.invalidate('qr');
      await pumpEventQueue();

      expect(bootstrap.hasInstance('qr'), isFalse);
      expect(bootstrap.debugInstanceCacheCount, 0);
      expect(states.last.phase, ModuleBootstrapPhase.absent,
          reason: 'invalidate 必须发布 absent 并清空该模块的缓存状态');
      final snapshot = await bootstrap.states.first;
      expect(snapshot.any((s) => s.module == 'qr'), isFalse,
          reason: 'absent 状态不得留在聚合快照中');
      await sub.cancel();
    });

    test('无缓存模块上 invalidate 为无害 no-op', () async {
      configureBootstrap();
      expect(bootstrap.debugInstanceCacheCount, 0);

      bootstrap.invalidate('ghost');
      await pumpEventQueue();

      expect(bootstrap.hasInstance('ghost'), isFalse);
      expect(bootstrap.debugInstanceCacheCount, 0);
      expect(bootstrap.debugInstanceInFlightCount, 0);
      expect(bootstrap.debugPendingEnsureCount, 0);
      expect(bootstrap.debugEnsureInFlightCount, 0);
    });
  });

  group('RustModuleLoader.invalidateModule（代号墓碑）', () {
    test('在途安装于写盘检查点前中止，且不强杀每模块单飞', () async {
      final bytes = Uint8List.fromList(List<int>.generate(32, (i) => i));
      final gate = Completer<Uint8List?>();
      final started = Completer<void>();
      final fetcher = _HeldFetcher(gate.future, started);
      final source = _FakeManifestClient(
        manifest: _loaderManifest(bytes),
        url: 'https://example.invalid/libgstore_mod_qr_0.5.0-arm64-v8a.so',
      );

      loader.debugConfigure(
        supportDir: tmp.path,
        manifestSource: source,
        downloader: fetcher,
        isLoadedOverride: (_) async => false,
        mountOverride: (_) async => true,
      );

      final ensure = loader.ensureModule('qr');
      await started.future; // 已进入真实下载（在途安装）。
      expect(fetcher.fetchCalls, 1);
      expect(loader.debugEnsureInFlightCount, 1,
          reason: '安装应真实在途（每模块单飞条目存在）');

      final invalidated = loader.invalidateModule('qr');
      expect(invalidated, isTrue, reason: '存在在途安装 → 返回 true');

      // 完成下载：在途尝试必须在写共享路径前发现自己已被取代而中止。
      gate.complete(bytes);
      final ok = await ensure;
      expect(ok, isFalse, reason: '被作废的安装必须在写盘前中止');

      // 单飞条目自然清理（绝不被强制移除），且无 `.so` 落盘。
      expect(loader.debugEnsureInFlightCount, 0,
          reason: '在途 future 自然结束后单飞条目应被释放');
      final moduleDir = Directory(p.join(tmp.path, 'gstore_modules', 'qr'));
      final soFiles = moduleDir.existsSync()
          ? moduleDir
              .listSync()
              .whereType<File>()
              .where((f) => f.path.endsWith('.so'))
              .toList()
          : <File>[];
      expect(soFiles, isEmpty, reason: '作废的安装绝不留下 .so 产物');
    });

    test('无在途安装 → 返回 false（无害 no-op）', () {
      loader.debugConfigure(
        supportDir: tmp.path,
        isLoadedOverride: (_) async => false,
      );
      expect(loader.invalidateModule('ghost'), isFalse);
    });
  });
}
