import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/fdroid/FdroidRepoModels.dart';
import 'package:gstore/core/rust/FdroidRustRepoManager.dart';
import 'package:gstore/core/rust/ModuleBootstrap.dart';
import 'package:gstore/core/rust/ModuleLoader.dart' show ModuleProgressCallback;
import 'package:gstore/core/rust/ModuleManager.dart';
import 'package:gstore/core/rust/generated/bridge.dart' show ModuleHandle;

/// 伪造的宿主模块句柄：仅经 `debugConfigure` 接缝注入，从不调用宿主方法。
class _FakeModuleHandle implements ModuleHandle {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

/// 伪造的模块实例：仅用于身份断言，不调用任何实例方法。
class _FakeInstance implements RustModuleInstance {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

/// 构造两个地址不同的源（fingerprint 为空 → 身份键为归一化 URL）。
FdroidSource _source(String id, String url) =>
    FdroidSource(id: id, name: id, repoUrl: url);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final bootstrap = ModuleBootstrap.instance;
  final manager = RustModuleManager.instance;

  setUp(() {
    bootstrap.debugReset();
    manager.debugReset();
    FdroidRustRepoManager.debugInstanceFactory = null;
  });

  tearDown(() {
    bootstrap.debugReset();
    manager.debugReset();
    FdroidRustRepoManager.debugInstanceFactory = null;
  });

  group('todo 14 - repo 实例经门获取', () {
    test('两个源：一次 repo ensure + 两个不同实例，并按 key 命中门缓存', () async {
      final handle = _FakeModuleHandle();
      var ensureCalls = 0;
      var factoryCalls = 0;

      bootstrap.debugConfigure(
        ensureOverride: (
          String module, {
          required bool allowDownload,
          ModuleProgressCallback? onProgress,
        }) async {
          ensureCalls++;
          return true;
        },
        loadOverride: (String module) async => handle,
        delayOverride: (Duration duration) async {},
      );
      FdroidRustRepoManager.debugInstanceFactory = (ModuleHandle h) async {
        factoryCalls++;
        return _FakeInstance();
      };

      final sourceA = _source('a', 'https://a.example/repo');
      final sourceB = _source('b', 'https://b.example/repo');

      final results = await Future.wait(<Future<RustModuleInstance>>[
        FdroidRustRepoManager.instanceForSource(sourceA),
        FdroidRustRepoManager.instanceForSource(sourceB),
      ]);

      expect(ensureCalls, 1, reason: 'ensure 只按模块去重：两个源共享一次 repo ensure');
      expect(factoryCalls, 2, reason: '两个身份键各创建一个实例');
      expect(identical(results[0], results[1]), isFalse,
          reason: '两个源必须是不同实例（各自的库）');

      final again = await FdroidRustRepoManager.instanceForSource(sourceA);
      expect(identical(again, results[0]), isTrue,
          reason: '同一身份键应命中门缓存复用实例');
      expect(ensureCalls, 1, reason: '缓存命中不再 ensure');
      expect(factoryCalls, 2, reason: '缓存命中不再创建实例');
    });

    test('未安装：instanceForSource 走 on-use 安装（allowDownload=true），非启动的 prepareExisting', () async {
      final handle = _FakeModuleHandle();
      final allowFlags = <bool>[];
      final modules = <String>[];
      var factoryCalls = 0;

      bootstrap.debugConfigure(
        ensureOverride: (
          String module, {
          required bool allowDownload,
          ModuleProgressCallback? onProgress,
        }) async {
          modules.add(module);
          allowFlags.add(allowDownload);
          return true;
        },
        loadOverride: (String module) async => handle,
        delayOverride: (Duration duration) async {},
      );
      FdroidRustRepoManager.debugInstanceFactory = (ModuleHandle h) async {
        factoryCalls++;
        return _FakeInstance();
      };

      final source = _source('a', 'https://a.example/repo');
      final inst = await FdroidRustRepoManager.instanceForSource(source);

      expect(inst, isNotNull, reason: '首次真实使用按需安装后应返回实例');
      expect(modules, <String>['repo'], reason: 'on-use 路径确保 repo');
      expect(allowFlags, <bool>[true],
          reason: '首次真实使用允许下载（与 initialize 的 allowDownload=false 相反）');
      expect(factoryCalls, 1, reason: '安装完成后创建一次实例');
    });

    test('已安装：instanceForSource 命中门缓存，行为不变（零新增 ensure/工厂）', () async {
      final handle = _FakeModuleHandle();
      var ensureCalls = 0;
      var factoryCalls = 0;

      bootstrap.debugConfigure(
        ensureOverride: (
          String module, {
          required bool allowDownload,
          ModuleProgressCallback? onProgress,
        }) async {
          ensureCalls++;
          return true;
        },
        loadOverride: (String module) async => handle,
        delayOverride: (Duration duration) async {},
      );
      FdroidRustRepoManager.debugInstanceFactory = (ModuleHandle h) async {
        factoryCalls++;
        return _FakeInstance();
      };

      final source = _source('a', 'https://a.example/repo');
      final first = await FdroidRustRepoManager.instanceForSource(source);
      expect(ensureCalls, 1, reason: '首次安装恰好一次 ensure');
      expect(factoryCalls, 1, reason: '首次安装创建一次实例');

      final second = await FdroidRustRepoManager.instanceForSource(source);
      expect(identical(second, first), isTrue,
          reason: '已安装后复用门缓存实例：行为不变');
      expect(ensureCalls, 1, reason: '缓存命中不再 ensure');
      expect(factoryCalls, 1, reason: '缓存命中不再创建实例');
    });

    test('initialize 仅 prepareExisting：allowDownload=false、不建实例、不下载', () async {
      manager.debugConfigure(readyOverride: () async {});

      final allowFlags = <bool>[];
      final modules = <String>[];
      var factoryCalls = 0;

      bootstrap.debugConfigure(
        ensureOverride: (
          String module, {
          required bool allowDownload,
          ModuleProgressCallback? onProgress,
        }) async {
          modules.add(module);
          allowFlags.add(allowDownload);
          // 无本地/内置产物时 prepareExisting 返回 false。
          return false;
        },
        loadOverride: (String module) async => _FakeModuleHandle(),
        factoryOverride: (ModuleHandle h) async {
          factoryCalls++;
          return _FakeInstance();
        },
      );

      await FdroidRustRepoManager.initialize();

      expect(modules, <String>['repo'], reason: 'initialize 只确保 repo');
      expect(allowFlags, <bool>[false],
          reason: '启动路径必须以 allowDownload=false 调用 ensure');
      expect(allowFlags.every((flag) => flag == false), isTrue,
          reason: 'initialize 绝不允许下载');
      expect(factoryCalls, 0, reason: 'initialize 不创建实例（挂载在首次使用时发生）');
    });

    test('repo 不可用：instanceForSource 抛既有 StateError，调用方保持 null 行为', () async {
      bootstrap.debugConfigure(
        ensureOverride: (
          String module, {
          required bool allowDownload,
          ModuleProgressCallback? onProgress,
        }) async =>
            false,
        loadOverride: (String module) async => _FakeModuleHandle(),
        delayOverride: (Duration duration) async {},
      );
      FdroidRustRepoManager.debugInstanceFactory =
          (ModuleHandle h) async => _FakeInstance();

      final source = _source('a', 'https://a.example/repo');

      await expectLater(
        FdroidRustRepoManager.instanceForSource(source),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('FdroidRustRepoManager: repo 模块不可用'),
        )),
      );

      // 既有调用方 catch 后返回 null（行为不变）。
      final meta = await FdroidRustRepoManager.getRepoMetaIn(source);
      expect(meta, isNull,
          reason: 'repo 不可用时 getRepoMetaIn 保持返回 null 的既有契约');
    });
  });
}
