import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';
import 'package:gstore/core/module/module_manager.dart';
import 'package:gstore/core/service/badge_service.dart';
import 'package:gstore/core/update/app_update_info.dart';
import 'package:gstore/core/update/update_facade.dart';
import 'package:gstore/core/update/update_log.dart';
import 'package:gstore/core/update/update_manager.dart';
import 'package:gstore/page/update/logic.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 假 core backend：跳过真实渠道检测，回放固定结果。
///
/// 检测引擎已删除：`UpdateNotifier` 经 `UpdateFacade` 走 core backend，测试用
/// `UpdateFacade.backendOverride` 注入本 fake（不再有 fake UpdateManager 覆盖
/// 已删除的 `checkUpdates`）。
class _FakeCoreBackend implements UpdateBackend {
  _FakeCoreBackend(this.items);

  /// 本次检测的结果
  final List<AppUpdateInfo> items;

  @override
  Future<List<AppUpdateInfo>> check({required bool force}) async => items;

  @override
  Future<List<AppUpdateInfo>> run() async => items;

  @override
  Future<List<AppUpdateInfo>> list() async => items;

  @override
  Future<AppUpdateInfo?> checkApp(String appId, {String? channelCode}) async {
    for (final item in items) {
      if (item.appId == appId) return item;
    }
    return null;
  }

  @override
  Future<bool> markUpdated(String appId) async => true;

  @override
  Future<bool> hasUpdate(String appId) async =>
      items.any((item) => item.appId == appId);

  @override
  Future<int> count() async => items.length;

  @override
  Future<bool> cacheValid() async => false;
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
    UpdateFacade.backendOverride = null;
    await ModuleManager.instance.clear();
  });

  /// 注册状态仓库 + 注入 core backend 并构建可读 notifier 的 container。
  (ProviderContainer, UpdateNotifier) makeNotifier(
      List<AppUpdateInfo> items) {
    ModuleManager.instance.bind<UpdateManagerService>(UpdateManagerService());
    ModuleManager.instance.bind<BadgeService>(BadgeService());
    UpdateFacade.backendOverride = _FakeCoreBackend(items);
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
    // The facade mirrors results through broadcast streams; let the delivery
    // microtasks run before reading the mirrored state.
    await Future<void>.delayed(Duration.zero);

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
    await Future<void>.delayed(Duration.zero);

    final state = container.read(updateProvider);
    expect(state.checkFinished, isTrue);
    expect(state.showLog, isFalse);
    expect(state.updateList, isEmpty);
  });

  test('订阅前已恢复的缓存日志/结果：订阅后立即同步显示（回归）', () async {
    final fake = UpdateManagerService();
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
