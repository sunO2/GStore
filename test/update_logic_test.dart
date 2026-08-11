import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';
import 'package:gstore/core/service/badge_service.dart';
import 'package:gstore/core/update/app_update_info.dart';
import 'package:gstore/core/update/update_log.dart';
import 'package:gstore/core/update/update_manager.dart';
import 'package:gstore/page/update/logic.dart';

/// 假 UpdateManager：跳过真实渠道检测，回放固定结果并触发全部回调
/// （UpdateLogic 通过 UpdateManagerService.instance 查找，Get.put 注册后即可替换）
class _FakeUpdateManager extends UpdateManagerService {
  _FakeUpdateManager(this.items);

  /// 本次检测的结果
  final List<AppUpdateInfo> items;

  final RxList<AppUpdateInfo> fakeUpdateList = <AppUpdateInfo>[].obs;
  final RxBool fakeIsChecking = false.obs;

  /// 回调是否被接线（验证 UpdateLogic → UpdateManager 的连线）
  bool checkListFired = false;
  bool progressFired = false;
  bool logFired = false;

  @override
  RxList<AppUpdateInfo> get updateList => fakeUpdateList;

  @override
  RxBool get isChecking => fakeIsChecking;

  @override
  void onInit() {
    // 跳过缓存恢复（测试环境无真实数据库）
  }

  @override
  Future<void> checkUpdates({
    bool force = false,
    void Function(UpdateCheckProgress progress)? onProgress,
    void Function(CheckLogLevel level, String message)? onLog,
    void Function(List<String> appNames)? onCheckList,
  }) async {
    fakeIsChecking.value = true;
    onCheckList?.call(['示例应用']);
    checkListFired = onCheckList != null;
    onProgress?.call(const UpdateCheckProgress(
      appId: 'com.example.app',
      appName: '示例应用',
      index: 0,
      total: 1,
    ));
    progressFired = onProgress != null;
    onLog?.call(CheckLogLevel.info, '检测中...');
    logFired = onLog != null;
    fakeUpdateList.assignAll(items);
    fakeIsChecking.value = false;
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

  tearDown(() {
    Get.reset();
  });

  test('有更新：checkFinished=false 且默认展示更新列表（showLog=false）', () async {
    Get.put<UpdateManagerService>(_FakeUpdateManager([_sampleInfo()]));
    Get.put(BadgeService());
    final logic = UpdateLogic();

    await logic.checkUpdates();

    // 回调全部接线（onCheckList 预填滚轮名单 / onProgress 进度 / onLog 日志）
    expect(logic.state.checkList, ['示例应用']);
    expect(logic.state.checkLog, isNotEmpty);
    // 回归点：有更新时不得进入"均无更新"完成态，默认展示更新列表
    expect(logic.state.checkFinished.value, isFalse);
    expect(logic.state.showLog.value, isFalse);
    expect(logic.state.updateList, hasLength(1));
    expect(logic.state.updateList.first.appName, '示例应用');
  });

  test('toggleLogView 在检测日志页与更新列表页之间切换', () async {
    Get.put<UpdateManagerService>(_FakeUpdateManager([_sampleInfo()]));
    Get.put(BadgeService());
    final logic = UpdateLogic();

    await logic.checkUpdates();
    expect(logic.state.showLog.value, isFalse);

    logic.toggleLogView(); // → 检测日志页
    expect(logic.state.showLog.value, isTrue);

    logic.toggleLogView(); // → 更新列表页
    expect(logic.state.showLog.value, isFalse);
  });

  test('无更新：checkFinished=true 停留检测日志页展示完整日志', () async {
    Get.put<UpdateManagerService>(_FakeUpdateManager([]));
    Get.put(BadgeService());
    final logic = UpdateLogic();

    await logic.checkUpdates();

    expect(logic.state.checkFinished.value, isTrue);
    expect(logic.state.showLog.value, isFalse);
    expect(logic.state.updateList, isEmpty);
  });
}
