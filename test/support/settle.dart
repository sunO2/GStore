import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

/// 有界轮询真实异步直到 [ready] 成立。
///
/// QuickJS FFI + 文件 IO 是非帧驱动的真实异步，其耗时不受测试时钟控制；
/// 全量测试并发时可能远超任意固定等待。固定 sleep 会让「导入完成」断言在
/// 慢机上偶发失败。这里只替换**等待机制**：交替 `runAsync`（推进真实事件
/// 循环）与 `pump`（推进测试时钟），以条件成立为退出条件并设上界；超时后
/// 仍不成立才失败，且给出明确原因。断言强度不变。
Future<void> settleUntil(
  WidgetTester tester,
  FutureOr<bool> Function() ready, {
  Duration timeout = const Duration(seconds: 20),
  String? reason,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump();
    if (await ready()) {
      await tester.pumpAndSettle();
      return;
    }
  }
  await tester.pumpAndSettle();
  if (await ready()) return;
  fail(reason ??
      'settleUntil: 条件在 ${timeout.inMilliseconds}ms 内未成立（等待上界，非断言放宽）');
}
