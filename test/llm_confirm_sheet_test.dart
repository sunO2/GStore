// Task 20：llm 安装确认经**统一 AppSheet**（`AppDialogs.showConfirmSheet`）呈现，
// 且「下载并继续」接受后驱动 `ModuleBootstrap.acquire('llm')` 完成、原
// `LocalLlmEngine` 调用得以继续（命中缓存，不再二次确认）；「取消」走既有
// 「模块不可用」StateError 路径。
//
// 全部用例为**密闭式**：仅经 `ModuleBootstrap.debugConfigure` 注入接缝 +
// 伪造 `ModuleHandle`/`InstanceHandle`，无 FFI、无网络、无真实下载；
// 弹层宿主复用 `appNavigatorKey` / `AppDialogs.scaffoldMessengerKey` 全局通道，
// 确认处理器直接复用生产入口 `lib/main.dart#confirmLargeModuleInstall`。
//
// 运行时执行按环境要求延后（系统盘故障：不执行 `flutter test`）。
//
// ignore_for_file: file_names

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/llm/local_llm_engine.dart';
import 'package:gstore/core/navigation/nav_key.dart';
import 'package:gstore/core/rust/ModuleBootstrap.dart';
import 'package:gstore/core/rust/ModuleLoader.dart' show ModuleProgressCallback;
import 'package:gstore/core/rust/generated/bridge.dart'
    show InstanceHandle, ModuleHandle;
import 'package:gstore/main.dart' as app;

/// 伪造实例句柄：仅服务于 `instanceId()`，不触碰 FFI。
class _FakeInstanceHandle implements InstanceHandle {
  @override
  Future<String> instanceId() async => 'llm-inst-1';

  @override
  Future<void> dispose() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 伪造宿主模块句柄：`createInstance` 返回假实例句柄，其余成员经
/// [noSuchMethod] 透传，**全程无 FFI**。
class _FakeModuleHandle implements ModuleHandle {
  int createCalls = 0;

  @override
  Future<InstanceHandle> createInstance({required List<int> config}) async {
    createCalls++;
    return _FakeInstanceHandle();
  }

  @override
  Future<void> dispose() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 测试宿主：与 `lib/main.dart` 相同的全局通道（Navigator / ScaffoldMessenger）。
Widget _host() => MaterialApp(
      navigatorKey: appNavigatorKey,
      scaffoldMessengerKey: AppDialogs.scaffoldMessengerKey,
      home: const Scaffold(body: SizedBox()),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final bootstrap = ModuleBootstrap.instance;
  final engine = LocalLlmEngine.instance;
  late _FakeModuleHandle handle;
  late int ensureCalls;
  late int confirmCalls;

  setUp(() {
    bootstrap.debugReset();
    engine.debugReset();
    handle = _FakeModuleHandle();
    ensureCalls = 0;
    confirmCalls = 0;
  });

  tearDown(() {
    bootstrap.debugReset();
    engine.debugReset();
  });

  /// 注入门接缝（无 FFI、无网络）：确认处理器复用生产入口并记录询问次数。
  void configure({required Future<bool> Function(String module) confirm}) {
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
      confirmHandler: (String module) {
        confirmCalls++;
        return confirm(module);
      },
    );
  }

  testWidgets('接受「下载并继续」→ 统一弹层呈现、acquire 完成、原任务返回且不再确认',
      (tester) async {
    configure(confirm: app.confirmLargeModuleInstall);
    await tester.pumpWidget(_host());

    // 原调用：LocalLlmEngine 首次使用 → 经确认策略门挂起在统一弹层上。
    final task = engine.ensureReady();
    await tester.pumpAndSettle();

    // 统一 AppSheet：标题 + arm64 / 体积文案 + 确认、取消按钮。
    expect(find.text('安装模块'), findsOneWidget);
    expect(
      find.textContaining('arm64'),
      findsOneWidget,
      reason: '文案须说明模块仅支持 arm64',
    );
    expect(
      find.textContaining('体积'),
      findsOneWidget,
      reason: '文案须给出下载体积级别',
    );
    expect(find.text('下载并继续'), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);

    await tester.tap(find.text('下载并继续'));
    await tester.pumpAndSettle();

    expect(await task, isTrue, reason: '接受后原任务应完成（恢复被挂起的调用）');
    expect(confirmCalls, 1, reason: '接受路径恰好确认一次');
    expect(ensureCalls, 1, reason: '确认通过后恰好一次 ensure');
    expect(handle.createCalls, 1, reason: '经 create(llm) 创建实例一次');

    // 再次使用：命中实例缓存，绝不二次确认。
    expect(await engine.ensureReady(), isTrue);
    expect(confirmCalls, 1, reason: '已就绪不得再次确认');
    expect(ensureCalls, 1, reason: '缓存命中不新增 ensure');
    expect(handle.createCalls, 1, reason: '实例仅创建一次');
  });

  testWidgets('拒绝「取消」→ 原任务返回 false、不 ensure，且后续走「模块不可用」路径',
      (tester) async {
    configure(confirm: app.confirmLargeModuleInstall);
    await tester.pumpWidget(_host());

    final task = engine.ensureReady();
    await tester.pumpAndSettle();

    expect(find.text('取消'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(await task, isFalse, reason: '拒绝不得抛错，返回 false');
    expect(confirmCalls, 1, reason: '拒绝路径恰好确认一次');
    expect(ensureCalls, 0, reason: '拒绝发生在 ensure 之前');
    expect(handle.createCalls, 0, reason: '拒绝不应创建实例');

    // 拒绝不粘滞：后续调用会重新询问；此处改用静默拒绝以避免再次弹层。
    bootstrap.setConfirmHandler((String module) async => false);
    await expectLater(
      engine.capabilities(),
      throwsA(isA<StateError>().having(
        (StateError e) => e.message,
        'message',
        '本地推理模块不可用（gstore_mod_llm 未安装或加载失败）',
      )),
      reason: '拒绝后 _call 沿用既有「模块不可用」StateError',
    );
    expect(ensureCalls, 0, reason: '再次拒绝仍不触发 ensure');
  });
}
