import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/design/app_sheet.dart';

/// AppSheetScaffold 键盘（viewInsets）几何验收。
///
/// 本文件拥有「键盘弹出时弹层不被顶出/裁剪」的几何验收（todo 4 只测表面行为）。
/// 直接 pump [AppSheetScaffold] 到带 `viewInsets` 的 [MediaQuery] 下，
/// **不**经过 `AppSheet.showCustom`（后者已用底部 padding 上推，会让测试
/// 在缺少 clamp 时也误通过）。
void main() {
  const double screenHeight = 800.0;
  const double topPadding = 24.0;
  const double factor = 0.8;

  MediaQueryData media({double insetBottom = 0}) => MediaQueryData(
        size: const Size(400, screenHeight),
        padding: const EdgeInsets.only(top: topPadding, bottom: 12),
        viewInsets: EdgeInsets.only(bottom: insetBottom),
      );

  Widget host(MediaQueryData data) => MaterialApp(
        home: MediaQuery(
          data: data,
          child: Scaffold(
            // 隔离 AppSheetScaffold 自身几何：不让 Scaffold 替我们压缩 viewInsets。
            resizeToAvoidBottomInset: false,
            body: AppSheetScaffold(
              title: '键盘测试',
              // 超长内容：正常情况下限高后由内部滚动消化。
              content: const SizedBox(height: 5000),
              actions: [
                FilledButton(onPressed: () {}, child: const Text('确认')),
              ],
            ),
          ),
        ),
      );

  /// 覆盖测试窗口尺寸，使 MediaQuery.size 与实际约束一致（默认 800x600
  /// 会把弹层约束压在 600，测不出 0.8 * 800 的比例限高）。
  void useTestSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(400, screenHeight);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  testWidgets('键盘弹出：高度被 viewInsets 压缩到可用高度内', (tester) async {
    useTestSurface(tester);
    await tester.pumpWidget(host(media(insetBottom: 300)));

    // 键盘压缩后的可用高度（扣掉 viewInsets 与顶部安全区）。
    final double available = screenHeight - 300 - topPadding; // 476
    // 未 clamp 时的比例限高。
    const double unclampedCap = screenHeight * factor; // 640

    // 反证：0.8 比例限高本身超过键盘压缩后的可用高度，
    // 若不做 clamp，弹层高度会是 640 而非 476 —— 证明 clamp 才是通过原因。
    expect(unclampedCap, greaterThan(available));

    final size = tester.getSize(find.byType(AppSheetScaffold));
    expect(
      size.height,
      lessThanOrEqualTo(available),
      reason: '键盘弹出时弹层不得高于可用高度，否则会被顶出/裁剪',
    );
    expect(size.height, moreOrLessEquals(available, epsilon: 0.5));
    expect(tester.takeException(), isNull);
  });

  testWidgets('无键盘：0.8 比例限高行为保持不变', (tester) async {
    useTestSurface(tester);
    await tester.pumpWidget(host(media()));

    final size = tester.getSize(find.byType(AppSheetScaffold));
    expect(
      size.height,
      moreOrLessEquals(screenHeight * factor, epsilon: 0.5),
      reason: 'viewInsets.bottom == 0 时保持原有 0.8 比例限高',
    );
    expect(tester.takeException(), isNull);
  });
}
