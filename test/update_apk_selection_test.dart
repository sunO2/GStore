import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/download/core/download_request.dart';
import 'package:gstore/core/download/model/download_task.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';
import 'package:gstore/core/model/IDetailInfo.dart';
import 'package:gstore/core/model/StatTag.dart';
import 'package:gstore/core/design/design_tokens.dart';
import 'package:gstore/core/module/interfaces/service_interfaces.dart';
import 'package:gstore/core/module/module_manager.dart';
import 'package:gstore/core/service/badge_service.dart';
import 'package:gstore/core/update/app_update_info.dart';
import 'package:gstore/core/update/update_cache.dart';
import 'package:gstore/core/update/update_log.dart';
import 'package:gstore/core/update/update_manager.dart';
import 'package:gstore/page/update/logic.dart';
import 'package:gstore/page/update/view.dart';
// ignore: depend_on_referenced_packages - 测试需替换 path_provider 平台实现
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 更新页 APK 展开选择（W4）widget 测试
///
/// 覆盖：
/// - 多候选卡片展开 → 显示全部候选，默认勾选 latestDownload（现规则结果）
/// - 点击另一候选 → 勾选切换 + UpdateCache.savePreferredApk 持久化
/// - 换选后点击"更新" → 下载使用用户所选（DownloadService mock 断言 fileName/version/url）
/// - 单候选 → 无展开入口
/// - detail=null（缓存恢复）→ 无展开入口
/// - 有偏好（SharedPreferences 预置）→ 默认勾选偏好匹配项

const _appId = 'com.example.app';
const _channelCode = 'github';

/// 假 UpdateManager：跳过真实渠道检测，直接回放固定结果
class _FakeUpdateManager extends UpdateManagerService {
  _FakeUpdateManager(this.items);

  final List<AppUpdateInfo> items;

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
    debugSetState(updateList: items);
  }
}

/// 最小 IDetailInfo：承载下载候选列表
class _FakeDetail implements IDetailInfo {
  _FakeDetail({required this.downloads});

  @override
  final List<DownloadInfo> downloads;

  @override
  String get appId => _appId;

  @override
  String get appName => '示例应用';

  @override
  String get channelId => _channelCode;

  @override
  ChannelType get channelType => ChannelType.github;

  @override
  String get description => '描述';

  @override
  String? get developer => null;

  @override
  Map<String, dynamic> get extra => const {};

  @override
  String get icon => '';

  @override
  bool get isValid => packageName.isNotEmpty && appName.isNotEmpty;

  @override
  String get name => appName;

  @override
  String get packageName => _appId;

  @override
  List<String>? get permissions => null;

  @override
  String? get projectUrl => null;

  @override
  String? get readme => null;

  @override
  String? get changelog => null;

  @override
  List<ScreenshotInfo>? get screenshots => null;

  @override
  List<DetailSection> get sections => const [];

  @override
  StatisticsInfo? get statistics => null;

  @override
  String? get version => '2.0.0';

  @override
  List<StatTag> buildStatTags() => const [];
}

DownloadInfo _dl(String name, {String? version}) => DownloadInfo(
      url: 'https://example.com/$name',
      name: name,
      size: 1000,
      version: version ?? '2.0.0',
    );

/// 多候选信息：默认选中 = latestDownload（universal，渠道 selectBestDownload 结果）
AppUpdateInfo _multiCandidateInfo() {
  final universal = _dl('app-universal-v2.0.0.apk');
  final arm = _dl('app-arm64-v8a-v2.0.0.apk');
  final x86 = _dl('app-x86_64-v2.0.0.apk');
  return AppUpdateInfo(
    channelId: _channelCode,
    appId: _appId,
    appName: '示例应用',
    packageName: _appId,
    installedVersion: '1.0.0',
    latestVersion: '2.0.0',
    latestDownload: universal,
    detail: _FakeDetail(downloads: [universal, arm, x86]),
  );
}

/// 混排候选信息：含 .apk/.zip/.txt，可安装候选 2 个 → 展开列表只显示 apk/aab
AppUpdateInfo _mixedCandidateInfo() {
  final universal = _dl('app-universal-v2.0.0.apk');
  final arm = _dl('app-arm64-v8a-v2.0.0.apk');
  final zip = _dl('app-arm64-v8a-v2.0.0.zip');
  final txt = _dl('notes.txt');
  return AppUpdateInfo(
    channelId: _channelCode,
    appId: _appId,
    appName: '示例应用',
    packageName: _appId,
    installedVersion: '1.0.0',
    latestVersion: '2.0.0',
    latestDownload: universal,
    detail: _FakeDetail(downloads: [universal, arm, zip, txt]),
  );
}

/// 过滤后单候选信息：仅 1 个 .apk，其余为 zip/txt → 无展开入口
AppUpdateInfo _singleApkWithJunkInfo() {
  final apk = _dl('app-universal-v2.0.0.apk');
  return AppUpdateInfo(
    channelId: _channelCode,
    appId: _appId,
    appName: '示例应用',
    packageName: _appId,
    installedVersion: '1.0.0',
    latestVersion: '2.0.0',
    latestDownload: apk,
    detail: _FakeDetail(downloads: [apk, _dl('app.zip'), _dl('notes.txt')]),
  );
}

/// 单候选信息：detail 有 1 个候选 → 无展开入口
AppUpdateInfo _singleCandidateInfo() {
  final dl = _dl('app-universal-v2.0.0.apk');
  return AppUpdateInfo(
    channelId: _channelCode,
    appId: _appId,
    appName: '示例应用',
    packageName: _appId,
    installedVersion: '1.0.0',
    latestVersion: '2.0.0',
    latestDownload: dl,
    detail: _FakeDetail(downloads: [dl]),
  );
}

/// 缓存恢复信息：detail=null → 无展开入口
AppUpdateInfo _cacheRestoredInfo() {
  final dl = _dl('app-universal-v2.0.0.apk');
  return AppUpdateInfo(
    channelId: _channelCode,
    appId: _appId,
    appName: '示例应用',
    packageName: _appId,
    installedVersion: '1.0.0',
    latestVersion: '2.0.0',
    latestDownload: dl,
    detail: null,
  );
}

/// 假下载服务：实现新 IDownloadService，记录 download / downloadWithContext 调用参数
class _FakeDownloadService implements IDownloadService {
  /// 记录的下载调用：(appId, appName, version, fileName, url)
  final List<(String, String, String, String, String)> calls = [];

  /// 构造一个处于"排队中"且无 id 的最小任务；
  /// id=null 使 UpdateLogic._awaitDownloadTerminal 立即返回（不订阅 watch），
  /// updateApp 只断言本次下载的 fileName/version/url 参数。
  DownloadTask _task(String appid, String appName, String version,
      String fileName, String url) {
    return DownloadTask(
      id: null,
      appId: appid,
      appName: appName,
      version: version,
      fileName: fileName,
      url: url,
      filePath: '/tmp/fake-$fileName.apk',
      total: 0,
      received: 0,
      status: DownloadStatusEnum.queued,
      speedBps: 0,
      etaSec: null,
      error: null,
      segments: null,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );
  }

  @override
  Future<DownloadTask> download(String appid, appName, version, url,
      fileName,
      {int? downloadSize,
      bool breakPoint = true,
      String? saveFileName,
      bool forceDownload = false,
      bool installAfterDownload = true}) async {
    calls.add((appid, appName, version, fileName, url));
    return _task(appid, appName, version, fileName, url);
  }

  @override
  Future<DownloadTask> downloadWithContext(
    DownloadRequest request,
    String appid,
    String appName,
    String version,
    String fileName, {
    bool breakPoint = true,
    String? saveFileName,
    bool installAfterDownload = true,
  }) async {
    calls.add((appid, appName, version, fileName, request.url));
    return _task(appid, appName, version, fileName, request.url);
  }

  @override
  Future<void> pause(int id) async {}

  @override
  Future<void> resume(int id) async {}

  @override
  Future<void> cancel(int id) async {}

  @override
  Future<void> retry(int id) async {}

  @override
  Future<DownloadTask?> getTask(int id) async => null;

  @override
  Stream<DownloadTask> watch(int id) => const Stream.empty();
}

/// mock path_provider 插件方法通道：getDownloadsDirectory 返回系统临时目录
/// 假 path_provider 平台实现：getDownloadsDirectory 返回系统临时目录
/// （MethodChannel mock 无效：path_provider_linux 注册了自己的平台实例）
class _FakePathProvider extends PathProviderPlatform {
  @override
  Future<String?> getDownloadsPath() async => Directory.systemTemp.path;
}

Future<void> _pumpUpdatePage(WidgetTester tester, AppUpdateInfo info) async {
  final fake = _FakeUpdateManager([info]);
  fake.debugSetState(
    updateList: [info],
    lastCheckedAt: DateTime.now(),
  );
  // 服务单例经 ModuleManager 解析：bind 让 UpdateManagerService.instance 命中 fake
  ModuleManager.instance.bind<UpdateManagerService>(fake);
  ModuleManager.instance.bind<BadgeService>(BadgeService());
  await tester.pumpWidget(
    ProviderScope(
      child: GetMaterialApp(home: const UpdateManager()),
    ),
  );
  await tester.pumpAndSettle();
}

/// 展开"选择 APK"并返回
Future<void> _expandApkSelector(WidgetTester tester) async {
  await tester.tap(find.text('选择 APK'));
  await tester.pumpAndSettle();
}

/// 某候选行是否带勾选图标
Finder _checkedIconOf(String name) => find.descendant(
      of: find.byKey(ValueKey('apk_option_$name')),
      matching: find.byIcon(Icons.check_circle),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late PathProviderPlatform originalPathProvider;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    originalPathProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _FakePathProvider();
  });

  tearDown(() async {
    PathProviderPlatform.instance = originalPathProvider;
    Get.reset();
    await ModuleManager.instance.clear();
  });

  group('APK 候选展开选择', () {
    testWidgets('多候选卡片：展开后显示全部候选，默认勾选 latestDownload 项', (tester) async {
      await _pumpUpdatePage(tester, _multiCandidateInfo());

      // 未展开时仅显示入口
      expect(find.text('选择 APK'), findsOneWidget);
      expect(find.text('app-arm64-v8a-v2.0.0.apk'), findsNothing);

      await _expandApkSelector(tester);

      // 全部候选可见（universal 额外出现在展开入口的当前选中文案中 → 2 处）
      expect(find.text('app-universal-v2.0.0.apk'), findsNWidgets(2));
      expect(find.text('app-arm64-v8a-v2.0.0.apk'), findsOneWidget);
      expect(find.text('app-x86_64-v2.0.0.apk'), findsOneWidget);
      // 默认勾选 = 现规则结果（latestDownload.name = universal）
      expect(_checkedIconOf('app-universal-v2.0.0.apk'), findsOneWidget);
      expect(_checkedIconOf('app-arm64-v8a-v2.0.0.apk'), findsNothing);
      expect(_checkedIconOf('app-x86_64-v2.0.0.apk'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('点击另一候选：勾选切换 + UpdateCache.savePreferredApk 持久化', (tester) async {
      await _pumpUpdatePage(tester, _multiCandidateInfo());
      await _expandApkSelector(tester);

      await tester.tap(find.text('app-arm64-v8a-v2.0.0.apk'));
      await tester.pumpAndSettle();

      // 勾选已切换
      expect(_checkedIconOf('app-universal-v2.0.0.apk'), findsNothing);
      expect(_checkedIconOf('app-arm64-v8a-v2.0.0.apk'), findsOneWidget);

      // 偏好已持久化（SharedPreferences mock 断言）
      final preferred =
          await UpdateCache.preferredApkName(_channelCode, _appId);
      expect(preferred, 'app-arm64-v8a-v2.0.0.apk');
      expect(tester.takeException(), isNull);
    });

    testWidgets('有偏好（预置 SharedPreferences）：默认勾选偏好匹配项', (tester) async {
      // 预置用户偏好（等价于历史会话保存过）
      await UpdateCache.savePreferredApk(
          _channelCode, _appId, 'app-arm64-v8a-v2.0.0.apk');
      await _pumpUpdatePage(tester, _multiCandidateInfo());
      await _expandApkSelector(tester);

      // 默认勾选 = 偏好匹配项（而非渠道默认 universal）
      expect(_checkedIconOf('app-arm64-v8a-v2.0.0.apk'), findsOneWidget);
      expect(_checkedIconOf('app-universal-v2.0.0.apk'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('单候选：无展开入口', (tester) async {
      await _pumpUpdatePage(tester, _singleCandidateInfo());

      expect(find.text('选择 APK'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('detail=null（缓存恢复）：无展开入口', (tester) async {
      await _pumpUpdatePage(tester, _cacheRestoredInfo());

      expect(find.text('选择 APK'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('候选含 .apk/.zip/.txt 混排：展开列表只显示 .apk/.aab', (tester) async {
      await _pumpUpdatePage(tester, _mixedCandidateInfo());
      await _expandApkSelector(tester);

      // universal 额外出现在展开入口当前选中文案中 → 2 处；arm 仅选项 1 处
      expect(find.text('app-universal-v2.0.0.apk'), findsNWidgets(2));
      expect(find.text('app-arm64-v8a-v2.0.0.apk'), findsOneWidget);
      // 非可安装文件不出现
      expect(find.text('app-arm64-v8a-v2.0.0.zip'), findsNothing);
      expect(find.text('notes.txt'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('过滤后仅 1 个 .apk（其余为 zip/txt）→ 无展开入口', (tester) async {
      await _pumpUpdatePage(tester, _singleApkWithJunkInfo());

      expect(find.text('选择 APK'), findsNothing);
      // 无展开入口 → 文件名不渲染（zip/txt 更不出现）
      expect(find.text('app-universal-v2.0.0.apk'), findsNothing);
      expect(find.text('app.zip'), findsNothing);
      expect(find.text('notes.txt'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('展开动画：AnimatedSize 展开 + 候选行交错入场，动画完成后全部可见', (tester) async {
      await _pumpUpdatePage(tester, _multiCandidateInfo());

      // AnimatedSize 包裹展开区
      expect(find.byType(AnimatedSize), findsOneWidget);

      // 展开：固定 pump 推进交错动画（勿 pumpAndSettle）
      await tester.tap(find.text('选择 APK'));
      await tester.pump();
      await tester.pump(AppAnimation.medium);
      await tester.pump(AppAnimation.medium);

      // 交错动画完成后候选全部可见（universal 额外出现在入口选中文案 → 2 处）
      expect(find.text('app-universal-v2.0.0.apk'), findsNWidgets(2));
      expect(find.text('app-arm64-v8a-v2.0.0.apk'), findsOneWidget);
      expect(find.text('app-x86_64-v2.0.0.apk'), findsOneWidget);
      expect(_checkedIconOf('app-universal-v2.0.0.apk'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('APK 文件名 Text：maxLines=2 且保留 ellipsis', (tester) async {
      await _pumpUpdatePage(tester, _multiCandidateInfo());
      await _expandApkSelector(tester);

      // 展开入口行（_ApkSelector）+ 选项行（_ApkOption）中的文件名均 maxLines=2
      final filenameTexts = tester
          .widgetList<Text>(find.text('app-universal-v2.0.0.apk'))
          .toList();
      expect(filenameTexts, isNotEmpty);
      for (final t in filenameTexts) {
        expect(t.maxLines, 2);
        expect(t.overflow, TextOverflow.ellipsis);
      }

      // 另一选项行（_ApkOption）中的文件名
      final optionText =
          tester.widget<Text>(find.descendant(
            of: find.byKey(ValueKey('apk_option_app-arm64-v8a-v2.0.0.apk')),
            matching: find.text('app-arm64-v8a-v2.0.0.apk'),
          ));
      expect(optionText.maxLines, 2);
      expect(optionText.overflow, TextOverflow.ellipsis);
      expect(tester.takeException(), isNull);
    });
  });

  group('updateApp 下载使用所选 APK（logic 级）', () {
    /// 构建注册 fake 服务 + 可读 notifier 的 container（listen 保活 autoDispose）。
    (ProviderContainer, UpdateNotifier) makeLogic(
        List<AppUpdateInfo> items) {
      // 服务单例经 ModuleManager 解析：bind 让 UpdateManagerService.instance 命中 fake
      ModuleManager.instance.bind<UpdateManagerService>(_FakeUpdateManager(items));
      ModuleManager.instance.bind<BadgeService>(BadgeService());
      final notifier = UpdateNotifier();
      final container = ProviderContainer(overrides: [
        updateProvider.overrideWith(() => notifier),
      ]);
      final sub = container.listen(updateProvider, (_, __) {});
      addTearDown(sub.close);
      addTearDown(container.dispose);
      return (container, notifier);
    }

    test('换选后 updateApp：下载使用用户所选（version/fileName/url）', () async {
      final info = _multiCandidateInfo();
      final fakeDownload = _FakeDownloadService();
      // UpdateNotifier 经注册表取用：同步绑定 ModuleManager 注册表
      ModuleManager.instance.bindByType(IDownloadService, fakeDownload);
      final (_, notifier) = makeLogic([info]);
      final arm = info.detail!.downloads[1];
      await notifier.selectApk(info, arm);

      // updateApp 内部下载失败路径走 AppDialogs（无宿主静默），不影响下载断言
      await notifier.updateApp(info);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(fakeDownload.calls, isNotEmpty);
      final (_, _, version, fileName, url) = fakeDownload.calls.last;
      expect(version, '2.0.0');
      expect(fileName, 'app-arm64-v8a-v2.0.0.apk');
      expect(url, 'https://example.com/app-arm64-v8a-v2.0.0.apk');
    });

    test('未换选 updateApp：下载使用默认 latestDownload', () async {
      final info = _multiCandidateInfo();
      final fakeDownload = _FakeDownloadService();
      // UpdateNotifier 经注册表取用：同步绑定 ModuleManager 注册表
      ModuleManager.instance.bindByType(IDownloadService, fakeDownload);
      final (_, notifier) = makeLogic([info]);

      await notifier.updateApp(info);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(fakeDownload.calls, isNotEmpty);
      final (_, _, _, fileName, url) = fakeDownload.calls.last;
      expect(fileName, 'app-universal-v2.0.0.apk');
      expect(url, 'https://example.com/app-universal-v2.0.0.apk');
    });
  });
}
