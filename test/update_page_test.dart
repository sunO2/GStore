import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:gstore/core/update/update_manager.dart';
import 'package:gstore/core/service/badge_service.dart';
import 'package:gstore/page/update/view.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('UpdateManager renders without error', (tester) async {
    // 注册 UpdateManagerService / BadgeService（build 后懒检测由服务内部处理）
    if (!Get.isRegistered<UpdateManagerService>()) {
      Get.put(UpdateManagerService());
    }
    if (!Get.isRegistered<BadgeService>()) {
      Get.put(BadgeService());
    }

    await tester.pumpWidget(
      ProviderScope(
        child: GetMaterialApp(home: const UpdateManager()),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
