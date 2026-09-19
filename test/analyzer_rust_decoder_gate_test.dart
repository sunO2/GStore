import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/rust/AnalyzerRustDecoder.dart';
import 'package:gstore/core/rust/ModuleBootstrap.dart';
import 'package:gstore/core/rust/ModuleLoader.dart' show ModuleProgressCallback;
import 'package:gstore/core/rust/ModuleManager.dart' show RustModuleInstance;
import 'package:gstore/core/rust/generated/bridge.dart' show ModuleHandle;
import 'package:mockito/mockito.dart';

/// 伪造的宿主模块句柄。
///
/// 仅经 `ModuleBootstrap.debugConfigure` 的 `loadOverride` 原样返回，从不调用
/// 任何宿主方法；[Mock] 的无实现透传即可，**不触碰 FFI**。
class _FakeModuleHandle extends Mock implements ModuleHandle {}

/// 伪造的模块实例：`callModule` 返回受控 JSON 字节并计数调用次数。
///
/// 其余成员经 [noSuchMethod] 透传，**不触碰 FFI**。
class _FakeRustModuleInstance implements RustModuleInstance {
  _FakeRustModuleInstance(this.response);

  final Uint8List response;
  int callCalls = 0;
  final List<String> methods = <String>[];

  @override
  Future<Uint8List> callModule(String method, [Uint8List? payload]) async {
    callCalls++;
    methods.add(method);
    return response;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

/// JSON 响应字节（模块 scan_dex_classes 契约）。
Uint8List _dexClassesJson(List<String> classes) =>
    Uint8List.fromList(utf8.encode(jsonEncode(classes)));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final bootstrap = ModuleBootstrap.instance;

  setUp(() {
    bootstrap.debugReset();
  });

  tearDown(() {
    bootstrap.debugReset();
  });

  group('analyzer 经 ModuleBootstrap.run 自举', () {
    test('安装期发出的调用等待 ensure 后完成：ensure 一次、任务一次、值正确', () async {
      final instance = _FakeRustModuleInstance(_dexClassesJson(<String>['a', 'b']));
      final ensureGate = Completer<bool>();
      var ensureCalls = 0;

      bootstrap.debugConfigure(
        ensureOverride: (
          String module, {
          required bool allowDownload,
          ModuleProgressCallback? onProgress,
        }) {
          ensureCalls++;
          expect(module, 'analyzer', reason: 'analyzer 走 analyzer 模块');
          return ensureGate.future;
        },
        loadOverride: (String module) async => _FakeModuleHandle(),
        factoryOverride: (ModuleHandle handle) async => instance,
      );

      // 在 ensure 仍挂起（安装中）时发起调用。
      final future =
          AnalyzerRustDecoder.scanDexClasses('/tmp/fake.apk', <String>['a']);
      var completed = false;
      future.then((_) => completed = true);
      await pumpEventQueue();

      expect(completed, isFalse, reason: '安装期调用必须等待，不得先返回 null');
      expect(ensureCalls, 1, reason: '发出调用即触发一次 ensure');
      expect(instance.callCalls, 0, reason: '实例未就绪前不得执行任务');

      // 安装完成：等待中的调用应继续并以解析出的实例执行一次。
      ensureGate.complete(true);
      final result = await future;

      expect(result, <String>['a', 'b'], reason: '应返回解码后的模块值');
      expect(ensureCalls, 1, reason: '调用仅触发一次 ensure');
      expect(instance.callCalls, 1, reason: '任务经解析实例恰好执行一次');
      expect(instance.methods, <String>['scan_dex_classes']);
    });

    test('已安装（门缓存实例）：多次调用复用实例、不新增 ensure，行为与未安装路径一致', () async {
      final instance = _FakeRustModuleInstance(_dexClassesJson(<String>['a', 'b']));
      var ensureCalls = 0;

      bootstrap.debugConfigure(
        ensureOverride: (
          String module, {
          required bool allowDownload,
          ModuleProgressCallback? onProgress,
        }) async {
          ensureCalls++;
          expect(module, 'analyzer', reason: 'analyzer 走 analyzer 模块');
          return true;
        },
        loadOverride: (String module) async => _FakeModuleHandle(),
        factoryOverride: (ModuleHandle handle) async => instance,
      );

      // 预热：模拟模块已安装完成、门已缓存 ready 实例。
      final warmed = await bootstrap.acquire('analyzer');
      expect(identical(warmed, instance), isTrue, reason: '预热得到门缓存实例');
      expect(ensureCalls, 1, reason: '预热安装恰好一次 ensure');

      // 已安装后的多次调用：全部经门缓存实例执行，after 阶段不再触发 ensure。
      for (var i = 0; i < 3; i++) {
        final result = await AnalyzerRustDecoder.scanDexClasses(
          '/tmp/fake.apk',
          <String>['a'],
        );
        expect(result, <String>['a', 'b'], reason: '已安装后行为不变：仍返回解码值');
      }

      expect(ensureCalls, 1, reason: '缓存命中不再 ensure');
      expect(instance.callCalls, 3, reason: '每次调用各执行一次任务，共享同一实例');
      expect(instance.methods, <String>[
        'scan_dex_classes',
        'scan_dex_classes',
        'scan_dex_classes',
      ]);
    });

    test('获取失败：所有公开方法返回 null 且无异常外泄', () async {
      var ensureCalls = 0;

      bootstrap.debugConfigure(
        // ensure 失败 → 门耗尽尝试后抛 ModuleInstallFailedException；
        // AnalyzerRustDecoder 必须捕获并返回 null。
        ensureOverride: (
          String module, {
          required bool allowDownload,
          ModuleProgressCallback? onProgress,
        }) async {
          ensureCalls++;
          return false;
        },
        loadOverride: (String module) async => _FakeModuleHandle(),
        factoryOverride: (ModuleHandle handle) async =>
            _FakeRustModuleInstance(_dexClassesJson(<String>['x'])),
        delayOverride: (Duration duration) async {},
      );

      final calls = <String, Future<Object?> Function()>{
        'parseApkInfo': () => AnalyzerRustDecoder.parseApkInfo('/tmp/a.apk'),
        'parseComponents':
            () => AnalyzerRustDecoder.parseComponents('/tmp/a.apk'),
        'scanDexClasses': () =>
            AnalyzerRustDecoder.scanDexClasses('/tmp/a.apk', <String>['a']),
        'scanElfPageSizes':
            () => AnalyzerRustDecoder.scanElfPageSizes('/tmp/a.apk'),
        'parseManifest': () => AnalyzerRustDecoder.parseManifest('/tmp/a.apk'),
        'scanDexStats': () => AnalyzerRustDecoder.scanDexStats('/tmp/a.apk'),
        'detectSignatureSchemes':
            () => AnalyzerRustDecoder.detectSignatureSchemes('/tmp/a.apk'),
        'scanFeatures': () => AnalyzerRustDecoder.scanFeatures('/tmp/a.apk'),
        'scanApkReport': () =>
            AnalyzerRustDecoder.scanApkReport('/tmp/a.apk', '[]'),
        'detectBuildVersions':
            () => AnalyzerRustDecoder.detectBuildVersions('/tmp/a.apk'),
        'matchLibraries': () =>
            AnalyzerRustDecoder.matchLibraries('/tmp/a.apk', '[]'),
        'scanApkStructure':
            () => AnalyzerRustDecoder.scanApkStructure('/tmp/a.apk'),
        'browseApkEntries':
            () => AnalyzerRustDecoder.browseApkEntries('/tmp/a.apk'),
        'exportApkEntry': () => AnalyzerRustDecoder.exportApkEntry(
              '/tmp/a.apk',
              entryPath: 'AndroidManifest.xml',
              outPath: '/tmp/out.bin',
            ),
      };

      for (final entry in calls.entries) {
        // 不得抛出：异常必须被吞掉并返回 null。
        final result = await entry.value();
        expect(result, isNull, reason: '${entry.key} 在模块不可用时必须返回 null');
      }

      expect(ensureCalls, greaterThan(0),
          reason: '每次调用都应尝试一次（并因失败重试）自举');
    });
  });
}
