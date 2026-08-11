import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:gstore/core/update/update_manager.dart';
import 'package:gstore/core/service/badge_service.dart';
import 'package:gstore/page/update/view.dart';

void main() {
  testWidgets('UpdateManager renders without error', (tester) async {
    // 注册 UpdateManagerService / BadgeService（UpdateLogic.onReady 会触发懒检测）
    if (!Get.isRegistered<UpdateManagerService>()) {
      Get.put(UpdateManagerService());
    }
    if (!Get.isRegistered<BadgeService>()) {
      Get.put(BadgeService());
    }

    await tester.pumpWidget(
      GetMaterialApp(home: const UpdateManager()),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
