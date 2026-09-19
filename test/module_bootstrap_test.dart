import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/rust/ModuleBootstrap.dart';
import 'package:gstore/core/rust/ModuleLoader.dart' show ModuleProgressCallback;
import 'package:gstore/core/rust/ModuleManager.dart' show RustModuleInstance;
import 'package:gstore/core/rust/generated/bridge.dart' show ModuleHandle;
import 'package:mockito/mockito.dart';

/// 安装确保回调（与 [ModuleBootstrap.debugConfigure] 的 `ensureOverride` 同型）。
typedef _EnsureFn = Future<bool> Function(
  String module, {
  required bool allowDownload,
  ModuleProgressCallback? onProgress,
});

/// 伪造的宿主模块句柄。
///
/// 本测试全程经 [ModuleBootstrap.debugConfigure] 注入接缝，句柄只被
/// `loadOverride` 原样返回、从不调用其任何宿主方法；因此 `Mock` 的无实现
/// 透传即可，**不触碰 FFI**。
class _FakeModuleHandle extends Mock implements ModuleHandle {}

/// 伪造的模块实例：仅用于身份/计数断言，不调用任何实例方法。
class _FakeRustModuleInstance extends Mock implements RustModuleInstance {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ModuleBootstrap bootstrap;
  late int ensureCalls;
  late int factoryCalls;
  late List<String> ensureModules;
  late List<Duration> delays;

  setUp(() {
    bootstrap = ModuleBootstrap.instance;
    bootstrap.debugReset();
    ensureCalls = 0;
    factoryCalls = 0;
    ensureModules = <String>[];
    delays = <Duration>[];
  });

  tearDown(() {
    bootstrap.debugReset();
  });

  /// 注入全部测试接缝（无 FFI、无网络）：ensure/factory 计数、假句柄、
  /// 退避记录、确认处理器。
  void configure({
    required _EnsureFn ensure,
    Future<bool> Function(String module)? confirm,
    Future<void> Function(Duration duration)? delay,
  }) {
    bootstrap.debugConfigure(
      ensureOverride: (
        String module, {
        required bool allowDownload,
        ModuleProgressCallback? onProgress,
      }) {
        ensureCalls++;
        ensureModules.add(module);
        return ensure(
          module,
          allowDownload: allowDownload,
          onProgress: onProgress,
        );
      },
      loadOverride: (String module) async => _FakeModuleHandle(),
      factoryOverride: (ModuleHandle handle) async {
        factoryCalls++;
        return _FakeRustModuleInstance();
      },
      delayOverride: delay ??
          (Duration duration) async {
            delays.add(duration);
          },
      confirmHandler: confirm,
    );
  }

  group('two-level-single-flight', () {
    test('(a) 并发 acquire 同 key：1 次 ensure + 1 次 factory，同一实例', () async {
      configure(
        ensure: (m, {required allowDownload, onProgress}) async => true,
      );

      final first = bootstrap.acquire('x');
      final second = bootstrap.acquire('x');
      final a = await first;
      final b = await second;

      expect(ensureCalls, 1, reason: '两个调用应共享同一次模块确保');
      expect(factoryCalls, 1, reason: '两个调用应共享同一次实例创建');
      expect(identical(a, b), isTrue, reason: '应返回同一实例');
    });

    test('(b) 并发 acquire 不同 instanceKey：1 次 ensure + 2 次 factory，实例不同', () async {
      configure(
        ensure: (m, {required allowDownload, onProgress}) async => true,
      );

      final first = bootstrap.acquire('x', instanceKey: 'k1');
      final second = bootstrap.acquire('x', instanceKey: 'k2');
      final a = await first;
      final b = await second;

      expect(ensureCalls, 1, reason: 'ensure 只按模块去重（与 instanceKey 无关）');
      expect(factoryCalls, 2, reason: '不同 instanceKey 各创建一次实例');
      expect(identical(a, b), isFalse, reason: '不同 key 应为不同实例');
    });

    test('(c) 并发 acquire 不同模块：2 次 ensure', () async {
      configure(
        ensure: (m, {required allowDownload, onProgress}) async => true,
      );

      final results = await Future.wait(<Future<RustModuleInstance>>[
        bootstrap.acquire('x'),
        bootstrap.acquire('y'),
      ]);

      expect(results.length, 2);
      expect(ensureCalls, 2, reason: '不同模块各自 ensure 一次');
      expect(ensureModules.toSet(), <String>{'x', 'y'});
      expect(factoryCalls, 2);
    });

    test('(d) 完成后再 acquire：零新增 ensure/factory（命中缓存）', () async {
      configure(
        ensure: (m, {required allowDownload, onProgress}) async => true,
      );

      final first = await bootstrap.acquire('x');
      expect(ensureCalls, 1);
      expect(factoryCalls, 1);

      final second = await bootstrap.acquire('x');
      expect(ensureCalls, 1, reason: '已缓存实例不应再次 ensure');
      expect(factoryCalls, 1, reason: '已缓存实例不应再次创建');
      expect(identical(first, second), isTrue);
    });
  });
}
