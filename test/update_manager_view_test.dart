import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';
import 'package:gstore/core/module/module_manager.dart';
import 'package:gstore/core/service/badge_service.dart';
import 'package:gstore/core/update/app_update_info.dart';
import 'package:gstore/core/update/update_log.dart';
import 'package:gstore/core/update/update_manager.dart';
import 'package:gstore/page/update/view.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 更新管理页 widget 测试
/// 复现"缓存有更新 → 点日志按钮 → 标题状态"场景
class _FakeUpdateManager extends UpdateManagerService {
  _FakeUpdateManager(this.items);

  final List<AppUpdateInfo> items;
  final RxList<AppUpdateInfo> fakeUpdateList = <AppUpdateInfo>[].obs;
  final RxBool fakeIsChecking = false.obs;

  @override
  RxList<AppUpdateInfo> get updateList => fakeUpdateList;

  @override
  RxBool get isChecking => fakeIsChecking;

  @override
  void onInit() {}

  @override
  Future<void> checkUpdates({
    bool force = false,
    void Function(UpdateCheckProgress progress)? onProgress,
    void Function(CheckLogLevel level, String message)? onLog,
    void Function(List<String> appNames)? onCheckList,
  }) async {
    checkList.assignAll(['示例应用']);
    checkedCount.value = 1;
    totalCount.value = 1;
    checkLog.assignAll(
        [CheckLogEntry(level: CheckLogLevel.info, text: '检测完成：发现 1 个可更新应用')]);
    fakeUpdateList.assignAll(items);
  }
}

AppUpdateInfo _sampleInfo() => AppUpdateInfo(
      channelId: 'github',
      appId: 'com.example.app',
      appName: '示例应用',
      packageName: 'com.example.app',
      installedVersion: '1.0.0',
      latestVersion: '2.0.0',
      latestDownload: DownloadInfo(
        url: 'https://example.com/app-2.0.0.apk',
        name: 'app-2.0.0.apk',
        size: 12345678,
        version: '2.0.0',
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() async {
    Get.reset();
    await ModuleManager.instance.clear();
  });

  testWidgets('缓存有更新：点日志按钮后标题显示"检测完成"而非"正在检测"', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final fake = _FakeUpdateManager([_sampleInfo()]);
    // 模拟缓存已恢复：有可更新结果 + 历史日志 + 上次检测时间
    fake.fakeUpdateList.assignAll([_sampleInfo()]);
    fake.checkLog.assignAll([
      CheckLogEntry(level: CheckLogLevel.update, text: '示例应用：发现更新 2.0.0'),
      CheckLogEntry(level: CheckLogLevel.info, text: '检测完成：发现 1 个可更新应用'),
    ]);
    fake.lastCheckedAt.value = DateTime.now();
    ModuleManager.instance.bind<UpdateManagerService>(fake);
    ModuleManager.instance.bind<BadgeService>(BadgeService());

    await tester.pumpWidget(
      const ProviderScope(
        child: GetMaterialApp(home: UpdateManager()),
      ),
    );
    await tester.pumpAndSettle();

    // 缓存优先：直接显示更新列表
    expect(find.text('发现 1 个可更新应用'), findsOneWidget);

    // 点右上角"检测日志"按钮
    await tester.tap(find.byTooltip('检测日志'));
    await tester.pumpAndSettle();

    // 标题应为完成状态（回归点：不得显示"正在检测"；标题与日志列表文本可重复）
    expect(find.textContaining('检测完成：发现 1 个可更新应用'), findsWidgets);
    expect(find.textContaining('正在检测更新'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('无更新缓存：进入直接显示检测完成页（含历史日志）', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final fake = _FakeUpdateManager([]);
    fake.checkLog.assignAll([
      CheckLogEntry(level: CheckLogLevel.none, text: '所有已添加应用均已是最新版本'),
    ]);
    fake.lastCheckedAt.value = DateTime.now();
    ModuleManager.instance.bind<UpdateManagerService>(fake);
    ModuleManager.instance.bind<BadgeService>(BadgeService());

    await tester.pumpWidget(
      const ProviderScope(
        child: GetMaterialApp(home: UpdateManager()),
      ),
    );
    await tester.pumpAndSettle();

    // 检测完成页（标题 + 历史日志），非"正在检测"
    expect(find.text('检测完成：所有应用均已是最新版本'), findsWidgets);
    expect(find.textContaining('正在检测更新'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
