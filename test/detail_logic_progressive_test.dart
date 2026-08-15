import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:gstore/core/channel/ChannelManager.dart';
import 'package:gstore/core/channel/IChannel.dart';
import 'package:gstore/core/channel/model/AppUpdateCheckResult.dart';
import 'package:gstore/core/channel/model/ChannelInfo.dart';
import 'package:gstore/core/channel/model/ChannelResult.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';
import 'package:gstore/core/model/AppDetailRequest.dart';
import 'package:gstore/core/model/AppSummary.dart';
import 'package:gstore/core/model/IDetailInfo.dart';
import 'package:gstore/core/model/StatTag.dart';
import 'package:gstore/db/apps/AppInfo.dart' as db;
import 'package:gstore/page/detail/logic.dart';

/// 详情页分块渐进加载（state/logic 层）纯逻辑单测。
///
/// 验证 loadDetail 重构：
/// a) getAppInfo 就绪 → 基础 detailInfo 立即可用（不等待三路）
/// b) 三路并行 + 渐进：downloads 先完成先注入，readme 未完成不阻塞
/// c) 独立降级：fetchDownloads 抛异常 → downloads null + loading 复位，readme/statistics 不受阻
/// d) 三路完成 → detailInfo 含 downloads/readme/statistics/version（createContext 可用）
/// e) fetchReadme 返回 null → readme null + loading 复位
///
/// InstalledApps 插件在单测环境调用抛 MissingPluginException——logic 已有
/// try/catch 容忍，断言时不涉及 installInfo。
class FakeChannel extends IChannel {
  FakeChannel({
    this.channelType = ChannelType.github,
    this.progressiveSupported = true,
  });

  final ChannelType channelType;

  /// 是否支持分块加载（false = 非分块渠道，loadDetail 走旧流程 getAppDetail）
  final bool progressiveSupported;

  /// 三路分块返回（默认立即成功；注入 Completer 可控制完成时序）
  Completer<ChannelResult<List<DownloadInfo>>>? downloadsCompleter;
  Completer<ChannelResult<String?>>? readmeCompleter;
  Completer<ChannelResult<Map<String, dynamic>?>>? statisticsCompleter;

  /// getAppDetail 返回的完整详情（非分块渠道旧流程用）
  IDetailInfo? getAppDetailResult;

  /// getAppDetail 调用次数
  int getAppDetailCalls = 0;

  /// 三路 fetch 总调用次数（非分块渠道旧流程不应调用任何一路）
  int fetchCalls = 0;

  /// getAppInfo 返回的基础信息
  AppSummary basic = const AppSummary(
    appId: 'owner/repo',
    packageName: 'com.example.app',
    name: '测试应用',
    user: 'owner',
    repositories: 'repo',
    icon: 'https://example.com/icon.png',
    des: '测试描述',
  );

  /// getAppInfo 调用次数
  int getAppInfoCalls = 0;

  @override
  ChannelInfo get info => ChannelInfo(
        type: channelType,
        name: channelType.code,
        description: '',
        priority: 1,
        enabled: true,
      );

  @override
  Future<ChannelResult<AppSummary?>> getAppInfo(
    String appId, {
    bool forceRefresh = false,
  }) async {
    getAppInfoCalls++;
    return ChannelResult.success(data: basic, from: channelType);
  }

  @override
  Future<ChannelResult<List<DownloadInfo>>> fetchDownloads(String appId) {
    fetchCalls++;
    return downloadsCompleter?.future ??
        Future.value(
          ChannelResult.success(data: const [], from: channelType),
        );
  }

  @override
  Future<ChannelResult<String?>> fetchReadme(String appId) {
    fetchCalls++;
    return readmeCompleter?.future ??
        Future.value(ChannelResult.success(data: null, from: channelType));
  }

  @override
  Future<ChannelResult<Map<String, dynamic>?>> fetchStatistics(String appId) {
    fetchCalls++;
    return statisticsCompleter?.future ??
        Future.value(
          ChannelResult.success(data: null, from: channelType),
        );
  }

  // ==================== 其余 IChannel 抽象成员最小实现 ====================

  @override
  bool get supportsProgressiveLoading => progressiveSupported;

  @override
  Future<ChannelResult<IDetailInfo>> getAppDetail(
    String appId, {
    bool forceRefresh = false,
  }) async {
    getAppDetailCalls++;
    final result = getAppDetailResult;
    if (result == null) throw UnimplementedError();
    return ChannelResult.success(data: result, from: channelType);
  }

  @override
  Future<void> initialize() async {}

  @override
  bool get isInitialized => true;

  @override
  Future<bool> checkAvailable() async => true;

  @override
  Future<String> canonicalAppId(AppSummary appInfo) async => appInfo.appId;

  @override
  Widget? getAddAppWidget(
    BuildContext context,
    Function(AppSummary) onAppAdded, {
    VoidCallback? onAppSaved,
  }) =>
      null;

  @override
  Future<ChannelResult<List<AppSummary>>> getAllApps({
    bool forceRefresh = false,
  }) async =>
      ChannelResult.success(data: const [], from: channelType);

  @override
  Future<ChannelResult<AppUpdateCheckResult>> checkAppUpdate(
    String appId,
  ) async {
    throw UnimplementedError();
  }

  @override
  Future<ChannelResult<void>> addApp(AppSummary app) async =>
      ChannelResult.success(data: null, from: channelType);

  @override
  Future<ChannelResult<void>> removeApp(String appId) async =>
      ChannelResult.success(data: null, from: channelType);

  @override
  Future<ChannelResult<List<AppSummary>>> searchApps(
    String keyword, {
    bool forceRefresh = false,
  }) async =>
      ChannelResult.success(data: const [], from: channelType);

  @override
  Future<ChannelResult<List<AppSummary>>> searchByCategory(
    String categoryId, {
    bool forceRefresh = false,
  }) async =>
      ChannelResult.success(data: const [], from: channelType);

  @override
  Future<ChannelResult<List<db.AppCategory>>> getAllCategories({
    bool forceRefresh = false,
  }) async =>
      ChannelResult.success(data: const [], from: channelType);

  @override
  Future<ChannelResult<bool>> checkUpdate() async =>
      ChannelResult.success(data: false, from: channelType);

  @override
  Future<ChannelResult<bool>> doUpdate({
    Function(int current, int total)? onProgress,
  }) async =>
      ChannelResult.success(data: true, from: channelType);

  @override
  Future<ChannelResult<db.AppInfoConfig?>> getConfig({
    bool forceRefresh = false,
  }) async =>
      ChannelResult.success(data: null, from: channelType);

  @override
  Future<void> clearCache() async {}

  @override
  Future<int> getCacheSize() async => 0;

  @override
  Future<void> dispose() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeChannel channel;
  late DetailLogic logic;

  setUp(() {
    Get.reset();
    channel = FakeChannel();
    ChannelManager.instance.registerChannel(channel);
    Get.put(ChannelManager.instance, tag: 'channelManager');

    logic = DetailLogic();
    logic.request = const AppDetailRequest(
      appId: 'owner/repo',
      name: '测试应用',
      packageName: 'com.example.app',
      channel: ChannelType.github,
    );
  });

  tearDown(() {
    logic.onClose();
    Get.reset();
  });

  test('a) getAppInfo 就绪后基础 detailInfo 立即可用（不等待三路）', () async {
    final future = logic.loadDetail();
    // 推进微任务：getAppInfo 完成 → 基础 detailInfo 已注入
    await pumpEventQueue();

    final detail = logic.state.detailInfo.value;
    expect(detail, isNotNull);
    expect(detail!.name, '测试应用');
    expect(detail.icon, 'https://example.com/icon.png');
    expect(detail.description, '测试描述');
    expect(detail.appId, 'owner/repo');
    expect(detail.channelType, ChannelType.github);
    expect(detail.packageName, 'com.example.app');
    expect(detail.developer, 'owner');
    expect(detail.projectUrl, 'https://github.com/owner/repo');
    // 三路未完成：区块仍为空
    expect(detail.downloads, isEmpty);
    expect(detail.sections, isEmpty);

    await future;
    expect(logic.state.isLoadingDetail.value, isFalse);
  });

  test('b) 三路并行渐进：downloads 先完成先注入，readme 后到达不阻塞', () async {
    final downloadsCompleter = Completer<ChannelResult<List<DownloadInfo>>>();
    final readmeCompleter = Completer<ChannelResult<String?>>();
    channel.downloadsCompleter = downloadsCompleter;
    channel.readmeCompleter = readmeCompleter;

    final future = logic.loadDetail();
    await pumpEventQueue();

    // 基础注入完成，三路都在等待
    expect(logic.state.detailInfo.value, isNotNull);
    expect(logic.state.downloadsLoading.value, isTrue);
    expect(logic.state.readmeLoading.value, isTrue);
    expect(logic.state.downloads.value, isNull);
    expect(logic.state.readme.value, isNull);

    // downloads 先完成
    downloadsCompleter.complete(
      ChannelResult.success(
        data: [
          DownloadInfo(
            url: 'https://example.com/a.apk',
            name: 'a.apk',
            version: '1.2.0',
          ),
        ],
        from: ChannelType.github,
      ),
    );
    await pumpEventQueue();

    expect(logic.state.downloads.value, hasLength(1));
    expect(logic.state.downloadsLoading.value, isFalse);
    // readme 未完成：不阻塞，仍加载中
    expect(logic.state.readme.value, isNull);
    expect(logic.state.readmeLoading.value, isTrue);

    final detail = logic.state.detailInfo.value!;
    expect(detail.downloads, hasLength(1));
    expect(detail.downloads.first.url, 'https://example.com/a.apk');
    expect(detail.version, '1.2.0'); // 最新版本随下载注入
    expect(detail.sections, contains(DetailSection.downloads));
    expect(detail.sections, isNot(contains(DetailSection.readme)));

    // readme 后完成
    readmeCompleter.complete(
      ChannelResult.success(data: '# README 内容', from: ChannelType.github),
    );
    await future;

    expect(logic.state.readme.value, '# README 内容');
    expect(logic.state.readmeLoading.value, isFalse);
    final finalDetail = logic.state.detailInfo.value!;
    expect(finalDetail.readme, '# README 内容');
    expect(finalDetail.sections, contains(DetailSection.readme));
    expect(finalDetail.sections, contains(DetailSection.downloads));
  });

  test('c) 独立降级：fetchDownloads 抛异常 → downloads null + loading 复位，readme/statistics 不受阻',
      () async {
    final downloadsCompleter = Completer<ChannelResult<List<DownloadInfo>>>();
    final readmeCompleter = Completer<ChannelResult<String?>>();
    final statisticsCompleter = Completer<ChannelResult<Map<String, dynamic>?>>();
    channel
      ..downloadsCompleter = downloadsCompleter
      ..readmeCompleter = readmeCompleter
      ..statisticsCompleter = statisticsCompleter;

    final future = logic.loadDetail();
    // 三路已进入等待（listener 已挂上）后再 completeError，
    // 错误由 loader 的 try/catch 捕获，而非落入测试 zone 未处理
    await pumpEventQueue();

    downloadsCompleter.completeError(Exception('网络不可用'));
    readmeCompleter.complete(
      ChannelResult.success(data: '# README', from: ChannelType.github),
    );
    statisticsCompleter.complete(
      ChannelResult.success(
        data: {'stargazers_count': 100, 'forks_count': 20},
        from: ChannelType.github,
      ),
    );
    await future;

    // downloads 区块独立降级
    expect(logic.state.downloads.value, isNull);
    expect(logic.state.downloadsLoading.value, isFalse);
    expect(logic.state.errorMessage.value, isEmpty); // 不触发整体错误

    // readme/statistics 不受阻
    expect(logic.state.readme.value, '# README');
    expect(logic.state.readmeLoading.value, isFalse);
    expect(logic.state.statisticsLoading.value, isFalse);

    final detail = logic.state.detailInfo.value!;
    expect(detail.sections, contains(DetailSection.readme));
    expect(detail.sections, contains(DetailSection.statistics));
    expect(detail.sections, isNot(contains(DetailSection.downloads)));
    expect(detail.extra['apiData'], {'stargazers_count': 100, 'forks_count': 20});
    expect(logic.state.isLoadingDetail.value, isFalse);
  });

  test('d) 三路全部完成：detailInfo 含 downloads/readme/statistics/version（createContext 可用）',
      () async {
    channel.downloadsCompleter = Completer()
      ..complete(ChannelResult.success(
        data: [
          DownloadInfo(
            url: 'https://example.com/a.apk',
            name: 'a.apk',
            version: '2.0.0',
          ),
        ],
        from: ChannelType.github,
      ));
    channel.readmeCompleter = Completer()
      ..complete(ChannelResult.success(data: '# 说明', from: ChannelType.github));
    channel.statisticsCompleter = Completer()
      ..complete(ChannelResult.success(
        data: {
          'stargazers_count': 100,
          'watchers_count': 10,
          'forks_count': 20,
          'full_name': 'owner/repo',
        },
        from: ChannelType.github,
      ));

    await logic.loadDetail();

    final detail = logic.state.detailInfo.value!;
    // 下载 / README / 统计 / 版本全部就绪
    expect(detail.downloads, hasLength(1));
    expect(detail.downloads.first.url, 'https://example.com/a.apk');
    expect(detail.readme, '# 说明');
    expect(detail.version, '2.0.0');
    expect(detail.statistics, isNotNull);
    expect(detail.statistics!.stars, 100);
    expect(detail.buildStatTags(), isNotEmpty);
    expect(detail.extra['apiData'], isA<Map<String, dynamic>>());

    // sections 增补齐全
    expect(detail.sections, contains(DetailSection.downloads));
    expect(detail.sections, contains(DetailSection.readme));
    expect(detail.sections, contains(DetailSection.statistics));

    // createContext 可用性：IDetailInfo 消费字段完整
    expect(detail.channelType, ChannelType.github);
    expect(detail.appId, 'owner/repo');
    expect(detail.name, '测试应用');
    expect(detail.developer, 'owner');
    expect(detail.projectUrl, 'https://github.com/owner/repo');
    expect(detail.extra['repositoryName'], 'repo');
    expect(detail.extra['developer'], 'owner');
    expect(logic.state.isLoadingDetail.value, isFalse);
  });

  test('e) fetchReadme 返回 null：readme 保持 null + loading 复位，不增补区块', () async {
    channel.readmeCompleter = Completer()
      ..complete(ChannelResult.success(data: null, from: ChannelType.github));

    await logic.loadDetail();

    expect(logic.state.readme.value, isNull);
    expect(logic.state.readmeLoading.value, isFalse);
    final detail = logic.state.detailInfo.value!;
    expect(detail.readme, isNull);
    expect(detail.sections, isNot(contains(DetailSection.readme)));
    expect(detail.extra.containsKey('readme'), isFalse);
    expect(logic.state.isLoadingDetail.value, isFalse);
  });

  test('f) 非分块渠道（supportsProgressiveLoading=false）→ 旧流程 getAppDetail 一次性完整注入，三路 fetch 不调用',
      () async {
    final legacyChannel = FakeChannel(progressiveSupported: false);
    ChannelManager.instance.registerChannel(legacyChannel);
    // 替换已注册的同渠道类型实例（getChannel 按 channelType 查找）
    logic.request = const AppDetailRequest(
      appId: 'owner/repo',
      name: '测试应用',
      packageName: 'com.example.app',
      channel: ChannelType.github,
    );

    final fullDetail = _FakeDetailInfo();
    legacyChannel.getAppDetailResult = fullDetail;

    await logic.loadDetail();

    // 旧流程：getAppDetail 恰好调用一次（getAppInfo 前置基础 + getAppDetail 主体）
    expect(legacyChannel.getAppDetailCalls, 1);
    // 三路 fetch 全部未被调用（非分块渠道不拆三路）
    expect(legacyChannel.fetchCalls, 0);

    // detailInfo 一次性完整注入（与 getAppDetail 返回同一实例）
    final detail = logic.state.detailInfo.value;
    expect(identical(detail, fullDetail), isTrue);
    expect(detail!.sections, contains(DetailSection.downloads));
    expect(detail.sections, contains(DetailSection.readme));
    expect(detail.sections, contains(DetailSection.statistics));
    expect(detail.screenshots, hasLength(1));
    expect(detail.changelog, '更新日志');
    expect(detail.permissions, contains('INTERNET'));
    expect(detail.version, '1.2.0');
    expect(logic.state.isLoadingDetail.value, isFalse);
    expect(logic.state.errorMessage.value, isEmpty);
  });

  test('g) fetchStatistics 带 metadata versionName → version 优先于 downloads 首项', () async {
    channel.downloadsCompleter = Completer()
      ..complete(ChannelResult.success(
        data: [
          DownloadInfo(
            url: 'https://example.com/a.apk',
            name: 'a.apk',
            version: '1.2.0',
          ),
        ],
        from: ChannelType.github,
      ));
    channel.statisticsCompleter = Completer()
      ..complete(ChannelResult.success(
        data: {
          'stargazers_count': 100,
          'forks_count': 20,
          'versionName': '2.1.0',
          'versionCode': 210,
          'metadata': {'versionName': '2.1.0', 'versionCode': 210},
        },
        from: ChannelType.github,
      ));

    await logic.loadDetail();

    final detail = logic.state.detailInfo.value!;
    // metadata versionName（APK 提取）优先于 releases 首项 version
    expect(detail.version, '2.1.0');
    // metadata 全量进入 extra（versionCode 供更新检测消费）
    expect(detail.extra['metadata'], {'versionName': '2.1.0', 'versionCode': 210});
    expect(detail.extra['apiData'], isA<Map<String, dynamic>>());
    expect(logic.state.isLoadingDetail.value, isFalse);
  });

  test('h) fetchStatistics 无 versionName → version 保持 downloads 首项（回归）', () async {
    channel.downloadsCompleter = Completer()
      ..complete(ChannelResult.success(
        data: [
          DownloadInfo(
            url: 'https://example.com/a.apk',
            name: 'a.apk',
            version: '1.2.0',
          ),
        ],
        from: ChannelType.github,
      ));
    channel.statisticsCompleter = Completer()
      ..complete(ChannelResult.success(
        data: {'stargazers_count': 100, 'forks_count': 20},
        from: ChannelType.github,
      ));

    await logic.loadDetail();

    final detail = logic.state.detailInfo.value!;
    expect(detail.version, '1.2.0');
    expect(detail.extra.containsKey('metadata'), isFalse);
    expect(logic.state.isLoadingDetail.value, isFalse);
  });
}

/// 旧流程 getAppDetail 返回的完整详情（覆盖截图/下载/更新日志/权限/评分等全部区块）
class _FakeDetailInfo extends IDetailInfo {
  @override
  String get packageName => 'com.example.app';

  @override
  String get appName => '测试应用';

  @override
  String get icon => 'https://example.com/icon.png';

  @override
  String get description => '完整详情描述';

  @override
  String get appId => 'owner/repo';

  @override
  String get channelId => 'github';

  @override
  ChannelType get channelType => ChannelType.github;

  @override
  String? get version => '1.2.0';

  @override
  String? get developer => 'owner';

  @override
  String? get projectUrl => 'https://github.com/owner/repo';

  @override
  List<DownloadInfo> get downloads => const [];

  @override
  List<DetailSection> get sections => const [
        DetailSection.statistics,
        DetailSection.version,
        DetailSection.downloads,
        DetailSection.readme,
      ];

  @override
  Map<String, dynamic> get extra => const {};

  @override
  String? get readme => '# 完整 README';

  @override
  List<ScreenshotInfo>? get screenshots =>
      [ScreenshotInfo(url: 'https://example.com/s1.png')];

  @override
  String? get changelog => '更新日志';

  @override
  List<String>? get permissions => const ['INTERNET'];

  @override
  StatisticsInfo? get statistics =>
      StatisticsInfo(stars: 100, forks: 20);

  @override
  List<StatTag> buildStatTags() => const [];
}
