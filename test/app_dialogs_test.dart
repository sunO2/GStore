import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/design/app_dialogs.dart';

void main() {
  /// 测试宿主：挂载 AppDialogs.scaffoldMessengerKey 的 MaterialApp
  Widget buildHost({GlobalKey<ScaffoldMessengerState>? messengerKey}) {
    return MaterialApp(
      scaffoldMessengerKey: messengerKey,
      home: const Scaffold(body: SizedBox()),
    );
  }

  testWidgets('showSuccess 通过 ScaffoldMessengerKey 显示 SnackBar', (tester) async {
    await tester.pumpWidget(
      buildHost(messengerKey: AppDialogs.scaffoldMessengerKey),
    );

    AppDialogs.showSuccess('测试成功');

    await tester.pump();
    expect(find.text('测试成功'), findsOneWidget);

    // SnackBar 的 3s 自动消失由 Timer 驱动：入场动画完成后才创建 Timer，
    // 需两次推进时钟（第一次完成入场+创建 Timer，第二次触发 Timer 退场）
    await tester.pump(const Duration(seconds: 4));
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    expect(find.text('测试成功'), findsNothing);
  });

  testWidgets('showError 通过 ScaffoldMessengerKey 显示 SnackBar', (tester) async {
    await tester.pumpWidget(
      buildHost(messengerKey: AppDialogs.scaffoldMessengerKey),
    );

    AppDialogs.showError('测试失败');

    await tester.pump();
    expect(find.text('测试失败'), findsOneWidget);

    // SnackBar 的 3s 自动消失由 Timer 驱动：入场动画完成后才创建 Timer，
    // 需两次推进时钟（第一次完成入场+创建 Timer，第二次触发 Timer 退场）
    await tester.pump(const Duration(seconds: 4));
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    expect(find.text('测试失败'), findsNothing);
  });

  testWidgets('showSnackbar（无标题）只显示 message', (tester) async {
    await tester.pumpWidget(
      buildHost(messengerKey: AppDialogs.scaffoldMessengerKey),
    );

    AppDialogs.showSnackbar('普通提示', title: null);

    await tester.pump();
    expect(find.text('普通提示'), findsOneWidget);

    // SnackBar 的 3s 自动消失由 Timer 驱动：入场动画完成后才创建 Timer，
    // 需两次推进时钟（第一次完成入场+创建 Timer，第二次触发 Timer 退场）
    await tester.pump(const Duration(seconds: 4));
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    expect(find.text('普通提示'), findsNothing);
  });

  testWidgets('key 未挂载时不崩溃（fallback 静默）', (tester) async {
    // 普通 MaterialApp 不传 scaffoldMessengerKey → currentState 为 null
    await tester.pumpWidget(buildHost());

    // 不应抛同步或异步异常（GetX overlay 不可用时应静默跳过）
    AppDialogs.showSuccess('测试成功');

    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.pumpAndSettle();
  });
}
