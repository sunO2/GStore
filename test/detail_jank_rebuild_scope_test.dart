/// 详情页「上下滑动卡顿」重建范围回归测试（task 257）。
///
/// 用户报告：「详情列表现在上下滑动会卡顿，如果滑动到最底部，再回到顶部，
/// 顶部的数据会重新从 rust 获取吗？为什么会卡顿一下呢」。
///
/// 事实（本测试锁定的结构契约）：
///   1. 详情页**没有**任何滚动监听（无 ScrollController / NotificationListener /
///      VisibilityDetector）→ 滚动**不会**从 Rust 重新取数；数据只在进入时取一次，
///      其后由下载 watch 推送。
///   2. 卡顿来自重建范围：`view.dart` 根节点 `ref.watch(detailStateProvider)`，
///      而下载进度回调（`logic.dart` 原 `state.currentDownload = da; state.refresh()`）
///      每次都 `notifyListeners()` → 整页重建（下载中约 2 次/秒）。
///   3. 进度只驱动 FAB。修复：进度改由独立 [ValueNotifier]
///      （`DetailState.downloadProgressRevision`）承载，不经过整页 provider；
///      FAB 用 `ValueListenableBuilder` 订阅；下载订阅改为列表级
///      `service.watchAll()`（不再 per-task `service.watch(id)`）。
///
/// 这些测试在修复前会失败（整页每 tick 重建 / 存在 per-task 订阅）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/channel/ChannelManager.dart';
import 'package:gstore/core/channel/IChannel.dart';
import 'package:gstore/core/channel/IDetailChannel.dart';
import 'package:gstore/core/channel/model/ChannelInfo.dart';
import 'package:gstore/core/channel/model/ChannelResult.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/download/model/download_task.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';
import 'package:gstore/core/model/AppDetailRequest.dart';
import 'package:gstore/core/model/AppSummary.dart';
import 'package:gstore/core/model/IDetailInfo.dart';
import 'package:gstore/core/model/StatTag.dart';
import 'package:gstore/core/module/interfaces/service_interfaces.dart';
import 'package:gstore/core/module/module_manager.dart';
import 'package:gstore/page/detail/logic.dart';
import 'package:gstore/page/detail/view.dart';

// ==================== 假下载服务（列表级 watchAll + 计数 per-task watch） ====================

class _FakeService implements IDownloadService {
  final StreamController<DownloadTask> _watchAll =
      StreamController<DownloadTask>.broadcast();

  int watchAllCalls = 0;
  final List<int> watchCalls = <int>[];
  int downloadCalls = 0;
  DownloadTask? downloadResult;

  @override
  Future<DownloadTask> download(
    String appid,
    String appName,
    String version,
    String url,
    String fileName, {
    int? downloadSize,
    bool breakPoint = true,
    String? saveFileName,
    bool forceDownload = false,
    bool installAfterDownload = true,
  }) async {
    downloadCalls++;
    return downloadResult ?? _task(1);
  }

  @override
  Stream<DownloadTask> watchAll() {
    watchAllCalls++;
    return _watchAll.stream;
  }

  @override
  Stream<DownloadTask> watch(int id) {
    watchCalls.add(id);
    // 忠实模拟真实 RustDownloadService.watch(id)：对列表级流按 id 过滤，
    // 但**每条 watch(id) 都是一条独立订阅**（即一条独立的 500ms 原生轮询线程）。
    final out = StreamController<DownloadTask>.broadcast();
    _watchAll.stream.listen((t) {
      if (t.id == id) out.add(t);
    });
    return out.stream;
  }

  void emit(DownloadTask task) => _watchAll.add(task);

  Future<void> close() => _watchAll.close();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

DownloadTask _task(int id, {int received = 0, int total = 1000}) => DownloadTask(
      id: id,
      appId: 'com.example.app',
      appName: '示例',
      version: '1.0.0',
      fileName: 'app.apk',
      url: 'https://example.test/app.apk',
      filePath: '/tmp/detail-jank-$id.apk',
      total: total,
      received: received,
      status: DownloadStatusEnum.downloading,
      speedBps: 0,
      etaSec: null,
      error: null,
      segments: null,
      createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(1000),
    );

// ==================== 最小 IDetailInfo stub ====================

class _StubDetail implements IDetailInfo {
  @override
  List<AppLabel> get labels => const [];
  List<DownloadInfo> downloadsValue = const [];
  List<DetailSection> sectionsValue = const [];

  @override
  String get packageName => 'com.example.app';
  @override
  String get appName => '测试应用';
  @override
  String get name => '测试应用';
  @override
  String get icon => '';
  @override
  String get description => '';
  @override
  String get appId => 'com.example.app';
  @override
  bool get isValid => true;
  @override
  String get channelId => 'github';
  @override
  ChannelType get channelType => ChannelType.github;
  @override
  String? get version => '1.0.0';
  @override
  String? get developer => null;
  @override
  String? get projectUrl => null;
  @override
  List<DownloadInfo> get downloads => downloadsValue;
  @override
  List<DetailSection> get sections => sectionsValue;
  @override
  Map<String, dynamic> get extra => const {};
  @override
  String? get readme => null;
  @override
  List<ScreenshotInfo>? get screenshots => null;
  @override
  String? get changelog => null;
  @override
  List<String>? get permissions => null;
  @override
  StatisticsInfo? get statistics => null;
  @override
  List<StatTag> buildStatTags() => const [];
}

// ==================== 计数渠道（分块加载，用于「进入取一次 / 滚动不重取」） ====================

class _CountingChannel implements IChannel {
  int getAppInfoCalls = 0;
  int fetchDownloadsCalls = 0;
  int fetchReadmeCalls = 0;
  int fetchStatisticsCalls = 0;

  int get totalFetchCalls =>
      fetchDownloadsCalls + fetchReadmeCalls + fetchStatisticsCalls;

  /// 返回大量下载项，使详情页内容高于视口（可真实滚动）。
  int downloadCount = 40;

  @override
  ChannelInfo get info => ChannelInfo(
        type: ChannelType.github,
        name: 'github',
        description: '',
        priority: 1,
        enabled: true,
      );

  @override
  bool get supportsProgressiveLoading => true;

  @override
  Future<ChannelResult<AppSummary?>> getAppInfo(
    String appId, {
    bool forceRefresh = false,
  }) async {
    getAppInfoCalls++;
    return ChannelResult.success(
      data: const AppSummary(
        appId: 'owner/repo',
        packageName: 'com.example.app',
        name: '测试应用',
        user: 'owner',
        repositories: 'repo',
        icon: '',
        des: '描述',
      ),
      from: ChannelType.github,
    );
  }

  @override
  Future<ChannelResult<List<DownloadInfo>>> fetchDownloads(String appId) async {
    fetchDownloadsCalls++;
    return ChannelResult.success(
      data: [
        for (var i = 0; i < downloadCount; i++)
          DownloadInfo(
            url: 'https://example.test/a$i.apk',
            name: 'a$i.apk',
            version: '1.0.$i',
          ),
      ],
      from: ChannelType.github,
    );
  }

  @override
  Future<ChannelResult<String?>> fetchReadme(String appId) async {
    fetchReadmeCalls++;
    return ChannelResult.success(data: null, from: ChannelType.github);
  }

  @override
  Future<ChannelResult<Map<String, dynamic>?>> fetchStatistics(
      String appId) async {
    fetchStatisticsCalls++;
    return ChannelResult.success(data: null, from: ChannelType.github);
  }

  @override
  Future<void> initialize() async {}
  @override
  bool get isInitialized => true;
  @override
  Future<bool> checkAvailable() async => true;
  @override
  Future<void> dispose() async {}

  // 具体方法（IChannel 有默认实现，但 `implements` 仍需显式实现）：
  // 无渠道级 detail 通道 → 返回 null，让 DetailLogic 回落到 StandardDetailChannel。
  @override
  IDetailChannel? getDetailChannel(String appId) => null;
  @override
  void releaseDetailChannel(String appId) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await ModuleManager.instance.clear();
    DetailPage.debugBuildCount = 0;
    DetailPage.debugProgressBuildCount = 0;
  });

  // ==================== (a) 进度 tick 不重建整页 ====================

  test(
      'a) 进度 tick 不使页面级 provider watch 失效（整页 0 重建），只驱动进度修订号',
      () async {
    final service = _FakeService()..downloadResult = _task(1);
    addTearDown(service.close);
    ModuleManager.instance.bind<IDownloadService>(service);

    final container = ProviderContainer();
    addTearDown(container.dispose);
    final sub = container.listen(detailStateProvider, (_, __) {});
    addTearDown(sub.close);
    final state = container.read(detailStateProvider);

    final logic = DetailLogic(state: state);
    addTearDown(logic.shutdown);
    logic.request = const AppDetailRequest(
      appId: 'com.example.app',
      name: '示例',
      channel: ChannelType.github,
    );
    state.detailInfo = _StubDetail();

    var pageEmissions = 0;
    container.listen(detailStateProvider, (_, __) => pageEmissions++);
    var progressEmissions = 0;
    state.downloadProgressRevision.addListener(() => progressEmissions++);

    await logic.startDownload(
      DownloadInfo(
        url: 'https://example.test/app.apk',
        name: 'app.apk',
        version: '1.0.0',
      ),
    );
    await pumpEventQueue();

    // 基线：startDownload 自身的写入（currentDownload 初值）不计入。
    pageEmissions = 0;
    progressEmissions = 0;
    final watchAllAfterStart = service.watchAllCalls;

    const ticks = 10;
    for (var i = 0; i < ticks; i++) {
      service.emit(_task(1, received: (i + 1) * 50));
      await pumpEventQueue();
    }

    // ignore: avoid_print
    print(
      'DETAILJANK-a ticks=$ticks pageProviderEmissions=$pageEmissions '
      'progressEmissions=$progressEmissions '
      'watchAllCalls=$watchAllAfterStart perTaskWatchCalls=${service.watchCalls.length}',
    );

    expect(pageEmissions, 0,
        reason: '进度 tick 不得使整页 provider watch 失效（整页重建根因）');
    expect(progressEmissions, ticks,
        reason: '每个进度 tick 只通知进度修订号（仅进度区重建）');
    expect(service.watchCalls, isEmpty,
        reason: '详情页不得再创建 per-task service.watch(id)');
    expect(watchAllAfterStart, 1,
        reason: '详情页必须走列表级单订阅 service.watchAll()');
  });

  // ==================== (b) 进度 tick 不重建 DetailPage，只重建 FAB ====================

  testWidgets('b) 进度 tick 不重建 DetailPage，只重建 FAB/进度区', (tester) async {
    final service = _FakeService()..downloadResult = _task(1);
    addTearDown(service.close);
    ModuleManager.instance.bind<IDownloadService>(service);

    final logic = DetailLogic();
    addTearDown(logic.shutdown);
    logic.state.detailInfo = _StubDetail();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [detailStateProvider.overrideWith((ref) => logic.state)],
        child: const MaterialApp(home: DetailPage()),
      ),
    );
    // 页面 start（post-frame microtask）会置 '缺少参数' → 清掉使正文渲染。
    logic.state.errorMessage = '';
    await tester.pump();

    DetailPage.debugBuildCount = 0;
    DetailPage.debugProgressBuildCount = 0;

    // 模拟一次下载进度回调（下载服务原地更新 → 赋值 currentDownload）。
    logic.state.currentDownload = _task(1, received: 500, total: 1000);
    await tester.pump();

    // ignore: avoid_print
    print(
      'DETAILJANK-b pageBuilds=${DetailPage.debugBuildCount} '
      'progressBuilds=${DetailPage.debugProgressBuildCount}',
    );

    expect(DetailPage.debugBuildCount, 0,
        reason: '进度 tick 不得重建整页（修复前为 1/次）');
    expect(DetailPage.debugProgressBuildCount, greaterThanOrEqualTo(1),
        reason: '进度区（FAB）应随进度修订号重建');
    expect(find.text('50'), findsOneWidget,
        reason: 'FAB 进度应更新为 50%（received=500/total=1000）');
  });

  // ==================== (c) 进入取一次，滚动不重取 ====================

  test('c1) 进入详情时数据只取一次（getAppInfo / 三路各 1 次）', () async {
    final channel = _CountingChannel();
    ChannelManager.instance.registerChannel(channel);
    ModuleManager.instance.bindByType(ChannelManager, ChannelManager.instance);

    final logic = DetailLogic();
    addTearDown(logic.shutdown);
    logic.request = const AppDetailRequest(
      appId: 'owner/repo',
      name: '测试应用',
      packageName: 'com.example.app',
      channel: ChannelType.github,
    );

    await logic.loadDetail();

    // ignore: avoid_print
    print(
      'DETAILJANK-c1 getAppInfo=${channel.getAppInfoCalls} '
      'downloads=${channel.fetchDownloadsCalls} readme=${channel.fetchReadmeCalls} '
      'statistics=${channel.fetchStatisticsCalls}',
    );

    expect(channel.getAppInfoCalls, 1, reason: '基础信息进入时取一次');
    expect(channel.fetchDownloadsCalls, 1, reason: '下载列表进入时取一次');
    expect(channel.fetchReadmeCalls, 1, reason: 'README 进入时取一次');
    expect(channel.fetchStatisticsCalls, 1, reason: '统计进入时取一次');
  });

  testWidgets('c2) 上下滑动不重新拉取详情数据（fetch 计数不变、状态无通知）',
      (tester) async {
    final channel = _CountingChannel();
    ChannelManager.instance.registerChannel(channel);
    ModuleManager.instance.bindByType(ChannelManager, ChannelManager.instance);

    // 直接构造「已加载」详情（长内容，可真实滚动）：避免在 testWidgets 的假时钟
    // 下 await 平台插件（loadDetail 的安装检测）导致挂起。进入时取一次由 c1 断言。
    final logic = DetailLogic();
    addTearDown(logic.shutdown);
    logic.request = const AppDetailRequest(
      appId: 'owner/repo',
      name: '测试应用',
      packageName: 'com.example.app',
      channel: ChannelType.github,
    );
    logic.state.detailInfo = _StubDetail()
      ..downloadsValue = [
        for (var i = 0; i < 40; i++)
          DownloadInfo(
            url: 'https://example.test/a$i.apk',
            name: 'a$i.apk',
            version: '1.0.$i',
          ),
      ]
      ..sectionsValue = const [DetailSection.downloads];

    var emissions = 0;
    logic.state.addListener(() => emissions++);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [detailStateProvider.overrideWith((ref) => logic.state)],
        child: const MaterialApp(home: DetailPage()),
      ),
    );
    logic.state.errorMessage = '';
    await tester.pump();

    final baseGet = channel.getAppInfoCalls;
    final baseFetch = channel.totalFetchCalls;
    emissions = 0;

    // 滚到最底部再回顶部（用户描述的滑动路径）。
    await tester.drag(
      find.byType(SingleChildScrollView).first,
      const Offset(0, -1200),
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.drag(
      find.byType(SingleChildScrollView).first,
      const Offset(0, 1200),
    );
    await tester.pump(const Duration(milliseconds: 300));

    // ignore: avoid_print
    print(
      'DETAILJANK-c2 getAppInfo=$baseGet->${channel.getAppInfoCalls} '
      'fetch=$baseFetch->${channel.totalFetchCalls} stateEmissions=$emissions',
    );

    expect(channel.getAppInfoCalls, baseGet, reason: '滑动不得触发 getAppInfo');
    expect(channel.totalFetchCalls, baseFetch, reason: '滑动不得重新拉取详情数据');
    expect(emissions, 0, reason: '滑动不得改变详情状态（无滚动监听）');
  });
}
