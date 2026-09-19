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

/// 伪造的宿主模块句柄：仅被 `loadOverride` 原样返回，从不调用宿主方法，**不触碰 FFI**。
class _FakeModuleHandle extends Mock implements ModuleHandle {}

/// 伪造的模块实例：仅用于身份断言，不调用任何实例方法。
class _FakeRustModuleInstance extends Mock implements RustModuleInstance {}

/// TODO 22 —— 确认处理器 ↔ 门策略的端到端接线（**无 UI、无 FFI、无网络**）。
///
/// 只经 [ModuleBootstrap.debugConfigure] 注入接缝：假确认处理器返回 `true/false`
/// 驱动 `acquire('llm', policy: ModuleInstallPolicy.confirm)` 完成安装或拒绝；
/// `qr` 走默认 `auto` 策略因而**绝不**调用处理器；处理器抛错一律视为拒绝且不崩溃；
/// 拒绝结果**不缓存**，再次 `acquire` 会重新询问。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ModuleBootstrap bootstrap;
  late int ensureCalls;
  late int factoryCalls;
  late List<String> ensureModules;

  setUp(() {
    bootstrap = ModuleBootstrap.instance;
    bootstrap.debugReset();
    ensureCalls = 0;
    factoryCalls = 0;
    ensureModules = <String>[];
  });

  tearDown(() {
    bootstrap.debugReset();
  });

  /// 注入接缝（无 FFI、无网络）：ensure/factory 计数 + 假句柄 + 确认处理器。
  void configure({
    required _EnsureFn ensure,
    Future<bool> Function(String module)? confirm,
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
      delayOverride: (Duration duration) async {},
      confirmHandler: confirm,
    );
  }

  group('confirm-gate', () {
    test('accept -> 确认一次后安装完成并返回实例', () async {
      var handlerCalls = 0;
      configure(
        ensure: (m, {required allowDownload, onProgress}) async => true,
        confirm: (m) async {
          handlerCalls++;
          return true;
        },
      );

      final instance =
          await bootstrap.acquire('llm', policy: ModuleInstallPolicy.confirm);

      expect(instance, isNotNull, reason: '接受后应返回已创建的实例');
      expect(handlerCalls, 1, reason: '确认处理器应恰好被询问一次');
      expect(ensureCalls, 1, reason: '接受后应恰好安装一次');
      expect(ensureModules, <String>['llm']);
      expect(factoryCalls, 1, reason: '接受后应创建一次实例');
    });

    test('accept -> 第二次 acquire 命中缓存，不再询问处理器', () async {
      var handlerCalls = 0;
      configure(
        ensure: (m, {required allowDownload, onProgress}) async => true,
        confirm: (m) async {
          handlerCalls++;
          return true;
        },
      );

      await bootstrap.acquire('llm', policy: ModuleInstallPolicy.confirm);
      await bootstrap.acquire('llm', policy: ModuleInstallPolicy.confirm);

      expect(handlerCalls, 1, reason: '已安装实例不应再次确认');
      expect(ensureCalls, 1);
      expect(factoryCalls, 1);
    });

    test('decline -> ModuleInstallDeclinedException 且从不 ensure', () async {
      var handlerCalls = 0;
      configure(
        ensure: (m, {required allowDownload, onProgress}) async => true,
        confirm: (m) async {
          handlerCalls++;
          return false;
        },
      );

      await expectLater(
        bootstrap.acquire('llm', policy: ModuleInstallPolicy.confirm),
        throwsA(isA<ModuleInstallDeclinedException>()),
      );

      expect(handlerCalls, 1, reason: '拒绝也应恰好询问一次');
      expect(ensureCalls, 0, reason: '拒绝必须发生在 ensure 之前');
      expect(factoryCalls, 0, reason: '拒绝不应创建实例');
    });

    test('decline 不缓存 -> 第二次 acquire 重新询问', () async {
      var handlerCalls = 0;
      configure(
        ensure: (m, {required allowDownload, onProgress}) async => true,
        confirm: (m) async {
          handlerCalls++;
          return false;
        },
      );

      await expectLater(
        bootstrap.acquire('llm', policy: ModuleInstallPolicy.confirm),
        throwsA(isA<ModuleInstallDeclinedException>()),
      );
      await expectLater(
        bootstrap.acquire('llm', policy: ModuleInstallPolicy.confirm),
        throwsA(isA<ModuleInstallDeclinedException>()),
      );

      expect(handlerCalls, 2, reason: '拒绝结果不缓存：第二次 acquire 会重新询问');
      expect(ensureCalls, 0);
      expect(factoryCalls, 0);
    });

    test('qr（auto 策略）-> 即使注册了处理器也绝不调用', () async {
      var handlerCalls = 0;
      configure(
        ensure: (m, {required allowDownload, onProgress}) async => true,
        confirm: (m) async {
          handlerCalls++;
          return true;
        },
      );

      // 未显式传 policy → 取 policyFor(qr) == auto。
      final instance = await bootstrap.acquire('qr');

      expect(instance, isNotNull);
      expect(handlerCalls, 0, reason: 'auto 策略模块永不调用确认处理器');
      expect(ensureCalls, 1);
      expect(ensureModules, <String>['qr']);
    });

    test('处理器抛错 -> 视为拒绝，不 ensure、不崩溃', () async {
      configure(
        ensure: (m, {required allowDownload, onProgress}) async => true,
        confirm: (m) async {
          throw StateError('boom');
        },
      );

      await expectLater(
        bootstrap.acquire('llm', policy: ModuleInstallPolicy.confirm),
        throwsA(isA<ModuleInstallDeclinedException>()),
      );

      expect(ensureCalls, 0, reason: '处理器异常被视为拒绝，不得进入安装');
      expect(factoryCalls, 0);
    });

    test('policyFor -> llm=confirm，其余=auto', () {
      expect(bootstrap.policyFor('llm'), ModuleInstallPolicy.confirm);
      for (final module in <String>[
        'qr',
        'analyzer',
        'repo',
        'download',
        'unknown',
      ]) {
        expect(
          bootstrap.policyFor(module),
          ModuleInstallPolicy.auto,
          reason: module,
        );
      }
    });
  });
}
