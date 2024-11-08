// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/utils/unit.dart';

void main() {
  testWidgets('Counter increments smoke test', (WidgetTester tester) async {
    // Build our app and trigger a frame.
    log("输出测试");
  });

  test("版本比较测试验证", () {
    var value = compareVersion("0.0.1", "0.0.2");
    expect(value, equals(1), reason: "结果怼了");
    value = compareVersion("1.0.2", "0.0.2");
    expect(value, equals(-1));
    value = compareVersion("0.0.2", "0.0.2");
    expect(value, equals(0));
  });
}
