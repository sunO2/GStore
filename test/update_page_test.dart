import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:gstore/page/update/view.dart';

void main() {
  testWidgets('UpdateManager renders without error', (tester) async {
    await tester.pumpWidget(
      GetMaterialApp(home: const UpdateManager()),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
