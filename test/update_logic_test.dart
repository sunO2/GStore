import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';
import 'package:gstore/core/module/module_manager.dart';
import 'package:gstore/core/service/badge_service.dart';
import 'package:gstore/core/update/app_update_info.dart';
import 'package:gstore/core/update/update_log.dart';
import 'package:gstore/core/update/update_manager.dart';
import 'package:gstore/page/update/logic.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 假 UpdateManager：跳过真实渠道检测，回放固定结果并触发全部回调
/// （UpdateNotifier 通过 UpdateManagerService.instance 查找，注册后即可替换）
class _FakeUpdateManager extends UpdateManagerService {
  _FakeUpdateManager(this.items);

  /// 本次检测的结果
  final List<AppUpdateInfo> items;

  /// 回调是否被接线（验证 UpdateNotifier → UpdateManager 的连线）
  bool checkListFired = false;
  bool progressFired = false;
  bool logFired = false;

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
    debugSetState(isChecking: true);
    // 共享状态（页面订阅镜像，与真实 manager 行为一致）
    debugSetState(
      checkList: ['示例应用'],
      checkedCount: 1,
      totalCount: 1,
      checkingAppName: '示例应用',
      checkLog: [
        CheckLogEntry(level: CheckLogLevel.info, text: '检测中...'),
      ],
    );
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
    debugSetState(updateList: items, isChecking: false);
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

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() async {
    await ModuleManager.instance.clear();
  });

  /// 注册 fake 服务并构建可读 notifier 的 container。
  (ProviderContainer, UpdateNotifier) makeNotifier(
      List<AppUpdateInfo> items) {
    ModuleManager.instance.bind<UpdateManagerService>(_FakeUpdateManager(items));
    ModuleManager.instance.bind<BadgeService>(BadgeService());
    final notifier = UpdateNotifier();
    final container = ProviderContainer(overrides: [
      updateProvider.overrideWith(() => notifier),
    ]);
    // listen（非裸 read）保持 autoDispose provider 活跃，避免 await 期间被回收
    final sub = container.listen(updateProvider, (_, __) {});
    addTearDown(sub.close);
    addTearDown(container.dispose);
    return (container, notifier);
  }

  test('有更新：checkFinished=false 且默认展示更新列表（showLog=false）', () async {
    final (container, notifier) = makeNotifier([_sampleInfo()]);

    await notifier.checkUpdates();

    final state = container.read(updateProvider);
    // 回调全部接线（onCheckList 预填滚轮名单 / onProgress 进度 / onLog 日志）
    expect(state.checkList, ['示例应用']);
    expect(state.checkLog, isNotEmpty);
    // 回归点：有更新时不得进入"均无更新"完成态，默认展示更新列表
    expect(state.checkFinished, isFalse);
    expect(state.showLog, isFalse);
    expect(state.updateList, hasLength(1));
    expect(state.updateList.first.appName, '示例应用');
  });

  test('toggleLogView 在检测日志页与更新列表页之间切换', () async {
    final (container, notifier) = makeNotifier([_sampleInfo()]);

    await notifier.checkUpdates();
    expect(container.read(updateProvider).showLog, isFalse);

    notifier.toggleLogView(); // → 检测日志页
    expect(container.read(updateProvider).showLog, isTrue);

    notifier.toggleLogView(); // → 更新列表页
    expect(container.read(updateProvider).showLog, isFalse);
  });

  test('无更新：checkFinished=true 停留检测日志页展示完整日志', () async {
    final (container, notifier) = makeNotifier([]);

    await notifier.checkUpdates();

    final state = container.read(updateProvider);
    expect(state.checkFinished, isTrue);
    expect(state.showLog, isFalse);
    expect(state.updateList, isEmpty);
  });

  test('订阅前已恢复的缓存日志/结果：订阅后立即同步显示（回归）', () async {
    final fake = _FakeUpdateManager([]);
    // 模拟缓存已在页面订阅前恢复（启动时 BadgeService 触发恢复）
    fake.debugSetState(
      checkLog: [
        CheckLogEntry(level: CheckLogLevel.info, text: '历史日志'),
      ],
      lastCheckedAt: DateTime.now(),
    );
    ModuleManager.instance.bind<UpdateManagerService>(fake);
    ModuleManager.instance.bind<BadgeService>(BadgeService());

    final notifier = UpdateNotifier();
    final container = ProviderContainer(overrides: [
      updateProvider.overrideWith(() => notifier),
    ]);
    addTearDown(container.dispose);
    // listen（非裸 read）保持 autoDispose provider 活跃，避免 microtask 间被回收
    final sub = container.listen(updateProvider, (_, __) {});
    addTearDown(sub.close);
    // build 的 _initialize 异步订阅服务并同步当前状态
    await Future<void>.delayed(Duration.zero);

    final state = container.read(updateProvider);
    // RxList.listen 不回调初始值 → 依赖订阅后显式同步
    expect(state.checkLog, isNotEmpty);
    expect(state.checkLog.first.text, '历史日志');
    expect(state.isLoading, isFalse);
  });
}
