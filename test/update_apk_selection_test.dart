import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/navigation/nav_key.dart';
import 'package:gstore/core/download/core/download_request.dart';
import 'package:gstore/core/download/model/download_task.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';
import 'package:gstore/core/model/IDetailInfo.dart';
import 'package:gstore/core/model/StatTag.dart';
import 'package:gstore/core/design/design_tokens.dart';
import 'package:gstore/core/module/interfaces/service_interfaces.dart';
import 'package:gstore/core/install/install_facade.dart';
import 'package:gstore/core/module/module_manager.dart';
import 'package:gstore/core/service/badge_service.dart';
import 'package:gstore/core/service/install_manager.dart';
import 'package:gstore/core/update/app_update_info.dart';
import 'package:gstore/core/update/update_facade.dart';
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
/// - 点击另一候选 → 勾选切换 + core 偏好持久化
/// - 换选后点击"更新" → 下载使用用户所选（DownloadService mock 断言 fileName/version/url）
/// - 单候选 → 无展开入口
/// - detail=null（缓存恢复）→ 无展开入口
/// - 有偏好（SharedPreferences 预置）→ 默认勾选偏好匹配项

const _appId = 'com.example.app';
const _channelCode = 'github';

/// 最小 IDetailInfo：承载下载候选列表
class _FakeDetail implements IDetailInfo {
  @override
  List<AppLabel> get labels => const [];
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
AppUpdateInfo _multiCandidateInfo({String channelId = _channelCode}) {
  final universal = _dl('app-universal-v2.0.0.apk');
  final arm = _dl('app-arm64-v8a-v2.0.0.apk');
  final x86 = _dl('app-x86_64-v2.0.0.apk');
  return AppUpdateInfo(
    channelId: channelId,
    appId: _appId,
    appName: '示例应用',
    packageName: _appId,
    installedVersion: '1.0.0',
    latestVersion: '2.0.0',
    latestDownload: universal,
    detail: _FakeDetail(downloads: [universal, arm, x86]),
  );
}

/// core 检测结果（detail 缺省）：候选来自 downloadCandidates。
///
/// [latestDownloadName] 用来模拟 Rust `list()` 按记忆偏好重投影的结果。
AppUpdateInfo _coreCandidateInfo({
  String latestDownloadName = 'app-universal-v2.0.0.apk',
  String channelId = _channelCode,
}) {
  final universal = _dl('app-universal-v2.0.0.apk');
  final arm = _dl('app-arm64-v8a-v2.0.0.apk');
  final x86 = _dl('app-x86_64-v2.0.0.apk');
  final latest =
      [universal, arm, x86].firstWhere((d) => d.name == latestDownloadName);
  return AppUpdateInfo(
    channelId: channelId,
    appId: _appId,
    appName: '示例应用',
    packageName: _appId,
    installedVersion: '1.0.0',
    latestVersion: '2.0.0',
    latestDownload: latest,
    downloadCandidates: [universal, arm, x86],
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

/// 假 core backend：实现偏好持久化接缝，避免 widget 测试触发真实 FRB。
///
/// [preferred] 以 `{channelId}:{appId}` 为键，模拟 Rust core 的偏好存储。
class _FakePreferenceBackend implements UpdateBackend, UpdatePreferenceBackend {
  final Map<String, String> preferred = <String, String>{};

  String _key(String channelId, String appId) => '$channelId:$appId';

  @override
  Future<void> setPreferredApk({
    required String channelId,
    required String appId,
    required String fileName,
  }) async {
    if (fileName.isEmpty) {
      preferred.remove(_key(channelId, appId));
    } else {
      preferred[_key(channelId, appId)] = fileName;
    }
  }

  @override
  Future<void> clearPreferredApk({
    required String channelId,
    required String appId,
  }) async {
    preferred.remove(_key(channelId, appId));
  }

  @override
  Future<String?> preferredApkName({
    required String channelId,
    required String appId,
  }) async =>
      preferred[_key(channelId, appId)];

  @override
  Future<List<AppUpdateInfo>> check({required bool force}) async => const [];

  @override
  Future<List<AppUpdateInfo>> run() async => const [];

  @override
  Future<List<AppUpdateInfo>> list() async => const [];

  @override
  Future<AppUpdateInfo?> checkApp(String appId, {String? channelCode}) async =>
      null;

  bool markUpdatedResult = true;

  @override
  Future<bool> markUpdated(String appId) async => markUpdatedResult;

  @override
  Future<bool> hasUpdate(String appId) async => false;

  @override
  Future<int> count() async => 0;

  @override
  Future<bool> cacheValid() async => false;
}

/// 已完成下载服务：id 非空且 getTask 返回 completed，供 updateApp 的安装/移除路径使用。
class _CompletedDownloadService implements IDownloadService {
  _CompletedDownloadService({this.installAfterDownload = true});

  final bool installAfterDownload;
  final List<(String, String, String, String, String)> calls = [];

  DownloadTask _completed(String appid, String appName, String version,
          String fileName, String url) =>
      DownloadTask(
        id: 42,
        appId: appid,
        appName: appName,
        version: version,
        fileName: fileName,
        url: url,
        filePath: '/tmp/$fileName',
        total: 100,
        received: 100,
        status: DownloadStatusEnum.completed,
        speedBps: 0,
        etaSec: null,
        error: null,
        segments: null,
        installAfterDownload: installAfterDownload,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

  @override
  Future<DownloadTask> download(
      String appid, String appName, String version, String url, String fileName,
      {int? downloadSize,
      bool breakPoint = true,
      String? saveFileName,
      bool forceDownload = false,
      bool installAfterDownload = true}) async {
    calls.add((appid, appName, version, fileName, url));
    _last = _completed(appid, appName, version, fileName, url);
    return _last!;
  }

  @override
  Future<DownloadTask> downloadWithContext(DownloadRequest request,
      String appid, String appName, String version, String fileName,
      {bool breakPoint = true,
      String? saveFileName,
      bool installAfterDownload = true}) async {
    calls.add((appid, appName, version, fileName, request.url));
    _last = _completed(appid, appName, version, fileName, request.url);
    return _last!;
  }

  @override
  Future<DownloadTask?> getTask(int id) async => _last;

  DownloadTask? _last;

  @override
  Future<List<DownloadTask>> listTasks() async =>
      _last == null ? const [] : [_last!];

  @override
  Stream<DownloadTask> watch(int id) => const Stream.empty();

  @override
  Stream<DownloadTask> watchAll() => const Stream<DownloadTask>.empty();

  @override
  Future<void> pause(int id) async {}

  @override
  Future<void> resume(int id) async {}

  @override
  Future<void> cancel(int id) async {}

  @override
  Future<void> retry(int id) async {}

  @override
  Future<void> restart(int id) async {}

  @override
  Future<void> remove(int id) async {}
}

class _FakeInstallManager implements InstallManager {
  int installTaskCalls = 0;

  @override
  Future<(InstallOutcome, InstallMethod)> installTask(
    String moduleTaskId,
    String filePath, {
    bool force = false,
  }) async {
    installTaskCalls++;
    return (InstallOutcome.installed, InstallMethod.shizuku);
  }

  @override
  Future<int> consumeInstallRequests() async => 0;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 假下载服务：实现新 IDownloadService，记录 download / downloadWithContext 调用参数
class _FakeDownloadService implements IDownloadService {
  _FakeDownloadService({this.completed = false});

  final bool completed;
  // --- 以下为实现 IDownloadService 新增成员（接口扩展后必须补齐，否则测试无法编译）---
  @override
  Future<List<DownloadTask>> listTasks() async => const [];

  @override
  Future<void> remove(int id) async {}

  @override
  Future<void> restart(int id) async {}

  @override
  Stream<DownloadTask> watchAll() => const Stream<DownloadTask>.empty();

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
      status:
          completed ? DownloadStatusEnum.completed : DownloadStatusEnum.queued,
      speedBps: 0,
      etaSec: null,
      error: null,
      segments: null,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );
  }

  @override
  Future<DownloadTask> download(String appid, appName, version, url, fileName,
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
  final fake = UpdateManagerService();
  fake.debugSetState(
    updateList: [info],
    lastCheckedAt: DateTime.now(),
  );
  // 服务单例经 ModuleManager 解析：bind 让 UpdateManagerService.instance 命中 fake
  ModuleManager.instance.bind<UpdateManagerService>(fake);
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
      matching: find.byIcon(TablerIcons.circle_check_filled),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late PathProviderPlatform originalPathProvider;
  late _FakePreferenceBackend fakeBackend;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    originalPathProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _FakePathProvider();
    fakeBackend = _FakePreferenceBackend();
    UpdateFacade.backendOverride = fakeBackend;
    ModuleManager.instance.bind<InstallManager>(_FakeInstallManager());
  });

  tearDown(() async {
    UpdateFacade.backendOverride = null;
    PathProviderPlatform.instance = originalPathProvider;
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

    testWidgets('点击另一候选：勾选切换 + core 偏好持久化（不走 SharedPreferences）',
        (tester) async {
      await _pumpUpdatePage(tester, _multiCandidateInfo());
      await _expandApkSelector(tester);

      await tester.tap(find.text('app-arm64-v8a-v2.0.0.apk'));
      await tester.pumpAndSettle();

      // 勾选已切换
      expect(_checkedIconOf('app-universal-v2.0.0.apk'), findsNothing);
      expect(_checkedIconOf('app-arm64-v8a-v2.0.0.apk'), findsOneWidget);

      // 偏好已写入 core backend（复合键）
      expect(
        fakeBackend.preferred['github:com.example.app'],
        'app-arm64-v8a-v2.0.0.apk',
      );
      // 生产路径不再写旧 SharedPreferences 缓存
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('update_preferred_apk'), isNull);
      expect(tester.takeException(), isNull);
    });

    testWidgets('core 已按偏好重投影 latestDownload：默认勾选 arm（非 universal）',
        (tester) async {
      // 模拟 Rust list() 记住偏好后重新投影：latestDownload = arm
      await _pumpUpdatePage(
        tester,
        _coreCandidateInfo(latestDownloadName: 'app-arm64-v8a-v2.0.0.apk'),
      );
      await _expandApkSelector(tester);

      // 默认勾选 = core 重投影的 latestDownload（arm），而非 universal
      expect(_checkedIconOf('app-arm64-v8a-v2.0.0.apk'), findsOneWidget);
      expect(_checkedIconOf('app-universal-v2.0.0.apk'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('detail=null + downloadCandidates：选择器显示且全部候选渲染',
        (tester) async {
      // 生产回归：Rust 切换后 detail 恒为 null，候选改由 downloads 数组提供
      await _pumpUpdatePage(
        tester,
        _coreCandidateInfo(latestDownloadName: 'app-universal-v2.0.0.apk'),
      );

      expect(find.text('选择 APK'), findsOneWidget);
      await _expandApkSelector(tester);

      expect(find.text('app-universal-v2.0.0.apk'), findsNWidgets(2));
      expect(find.text('app-arm64-v8a-v2.0.0.apk'), findsOneWidget);
      expect(find.text('app-x86_64-v2.0.0.apk'), findsOneWidget);
      expect(_checkedIconOf('app-universal-v2.0.0.apk'), findsOneWidget);
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
      final optionText = tester.widget<Text>(find.descendant(
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
    (ProviderContainer, UpdateNotifier) makeLogic(List<AppUpdateInfo> items) {
      // 服务单例经 ModuleManager 解析：bind 让 UpdateManagerService.instance 命中 fake
      final manager = UpdateManagerService()
        ..debugSetState(updateList: items, lastCheckedAt: DateTime.now());
      ModuleManager.instance.bind<UpdateManagerService>(manager);
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

    test('detail=null + downloadCandidates：换选后下载所选 arm64（端到端回归）', () async {
      final info = _coreCandidateInfo();
      final fakeDownload = _FakeDownloadService();
      ModuleManager.instance.bindByType(IDownloadService, fakeDownload);
      final (_, notifier) = makeLogic([info]);
      final arm = info.downloadCandidates[1];
      await notifier.selectApk(info, arm);

      // 内存镜像同步：离开/重返更新页时默认项仍是本次选择
      expect(
        UpdateManagerService.instance.updateList.single.latestDownload.name,
        'app-arm64-v8a-v2.0.0.apk',
      );

      await notifier.updateApp(info);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(fakeDownload.calls, isNotEmpty);
      final (_, _, version, fileName, url) = fakeDownload.calls.last;
      expect(version, '2.0.0');
      expect(fileName, 'app-arm64-v8a-v2.0.0.apk');
      expect(url, 'https://example.com/app-arm64-v8a-v2.0.0.apk');
    });

    test('markUpdated=false：安装未确认时保留更新项', () async {
      final info = _coreCandidateInfo();
      final fakeDownload = _CompletedDownloadService();
      ModuleManager.instance.bindByType(IDownloadService, fakeDownload);
      final (container, notifier) = makeLogic([info]);
      fakeBackend.markUpdatedResult = false;

      await notifier.updateApp(info);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final state = container.read(updateProvider);
      expect(state.updateList, hasLength(1), reason: '下载完成但安装未确认时不得从可更新列表移除');
      expect(state.updateList.single.appId, info.appId);
    });

    test('markUpdated=true：版本追平后才移除更新项', () async {
      final info = _coreCandidateInfo();
      final fakeDownload = _CompletedDownloadService();
      ModuleManager.instance.bindByType(IDownloadService, fakeDownload);
      final (container, notifier) = makeLogic([info]);
      fakeBackend.markUpdatedResult = true;

      await notifier.updateApp(info);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(container.read(updateProvider).updateList, isEmpty,
          reason: '安装确认且版本追平后才允许移除');
    });

    test('复合键：同 appId 不同 channelId 的选择互不干扰', () async {
      final github = _coreCandidateInfo();
      final fdroid = _coreCandidateInfo(channelId: 'fdroid');
      final fakeDownload = _FakeDownloadService();
      ModuleManager.instance.bindByType(IDownloadService, fakeDownload);
      final (container, notifier) = makeLogic([github, fdroid]);

      await notifier.selectApk(github, github.downloadCandidates[1]);
      await notifier.selectApk(fdroid, fdroid.downloadCandidates[2]);

      final state = container.read(updateProvider);
      expect(state.selectedApkName.keys,
          containsAll({'github:$_appId', 'fdroid:$_appId'}));
      expect(
          state.selectedApkName['github:$_appId'], 'app-arm64-v8a-v2.0.0.apk');
      expect(state.selectedApkName['fdroid:$_appId'], 'app-x86_64-v2.0.0.apk');

      // core backend 分别记录两个 channel 的偏好
      expect(
          fakeBackend.preferred['github:$_appId'], 'app-arm64-v8a-v2.0.0.apk');
      expect(fakeBackend.preferred['fdroid:$_appId'], 'app-x86_64-v2.0.0.apk');
    });
  });
}
