import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/module/module_manager.dart';
import 'package:gstore/core/navigation/nav_key.dart';
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
    ModuleManager.instance.bind<UpdateManagerService>(UpdateManagerService());
    ModuleManager.instance.bind<BadgeService>(BadgeService());

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          navigatorKey: appNavigatorKey,
          scaffoldMessengerKey: AppDialogs.scaffoldMessengerKey,
          home: const UpdateManager(),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
