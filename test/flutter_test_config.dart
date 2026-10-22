import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/rust/ModuleBootstrap.dart';
import 'package:gstore/core/rust/ModuleLoader.dart' show ModuleProgressCallback;
import 'package:gstore/core/rust/RustBridge.dart';

/// 全局测试配置。
///
/// 1. Task 5 起 `perf` 页**总是**尝试合并 BatteryManager 源；在 `testWidgets` 中
///    若 `gstore/battery` 通道没有 mock handler，`MethodChannel` 会永久挂起
///    （测试绑定不驱动真实 platform message）。这里统一注册一个返回 `null` 的
///    handler（等价「无原生实现」），让 `BatteryManagerChannel.read()` 快速降级。
/// 2. 模块自举门默认「无产物 / 无远程」：测试宿主（Linux）没有随包模块产物，
///    而一旦宿主机上存在构建出的 `libgstore_host.so`，FRB 初始化会成功，自举门
///    便继续走 loader 的真实磁盘/网络路径（`path_provider` 真实 IO、远程下载），
///    在 `testWidgets` 的 FakeAsync 下永不完成，页面无法进入既有降级分支。
///    这里注入只返回 `false` 的 ensure（零延迟、不加载、不下载、不触碰 FFI），
///    让所有模块消费方立即走既有「模块不可用」降级——与基线行为一致且确定。
///    需要真实自举行为的测试文件会在自身 setUp 中 `debugReset` + 重新注入。
/// 3. 同理，宿主机上存在 `libgstore_host.so` 时 `RustLib.init()` 会成功，真实
///    JNI/平台调用进入 `testWidgets` 的 FakeAsync（挂起、残留定时器或返回真机
///    数据），偏离基线的「无原生库」降级行为。这里默认把原生桥标记为不可用；
///    需要真实 FFI 的冒烟测试（`core_api_test`）自行解除。
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  TestWidgetsFlutterBinding.ensureInitialized();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('gstore/battery'),
    (call) async => null,
  );
  // 同理：`gstore/platform` 是 Android 宿主能力通道（Todo 4）。测试宿主没有它，
  // 且**未 mock 的 MethodChannel 在 `testWidgets` 的 FakeAsync 下永不回答**
  // （轮询 / 屏幕探测会挂起）。这里显式等价「无原生实现」：5 个桥接类的默认
  // reader 立即降级到既有兜底路径，与基线（无宿主 .so / 无通道）行为一致。
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('gstore/platform'),
    (call) async => null,
  );
  RustBridge.debugForceUnavailable = true;
  ModuleBootstrap.instance.debugConfigure(
    ensureOverride: (
      String module, {
      required bool allowDownload,
      ModuleProgressCallback? onProgress,
    }) async =>
        false,
    delayOverride: (Duration duration) async {},
  );
  await testMain();
}
