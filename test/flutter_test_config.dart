import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 全局测试配置。
///
/// Task 5 起 `perf` 页**总是**尝试合并 BatteryManager 源；在 `testWidgets` 中
/// 若 `gstore/battery` 通道没有 mock handler，`MethodChannel` 会永久挂起
/// （测试绑定不驱动真实 platform message）。这里统一注册一个返回 `null` 的
/// handler（等价「无原生实现」），让 `BatteryManagerChannel.read()` 快速降级。
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  TestWidgetsFlutterBinding.ensureInitialized();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('gstore/battery'),
    (call) async => null,
  );
  await testMain();
}
