import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:gstore/core/design/app_components.dart';
import 'package:gstore/core/service/db_manager.dart';
import 'package:gstore/db/apps/AppInfoDatabase.dart';
import 'package:gstore/http/download/DownloadStatus.dart';
import 'package:gstore/http/github/github_client.dart';
import 'package:gstore/page/download/download_status_utils.dart';
import 'package:gstore/page/download/logic.dart';
import 'package:gstore/page/download/view.dart';
import 'package:mockito/mockito.dart';

// ---------------------------------------------------------------------------
// 测试替身
//
// DownloadManagerLogic 的 `database` / `appInfoDB` 是 final 实例字段（非 getter），
// 子类无法覆写；且构造时即执行 `Get.find<GithubRestClient>()`（GithubRequestMix）
// 与 `"gstore".repoDB.db` → `Get.find<DbManager>()`。因此：
//  1. 测试前先注册 GithubRestClient / DbManager 占位实现，满足构造期依赖；
//  2. 子类覆写 onReady（不订阅真实 sqlite 数据库），由测试直接注入 downloadGroups；
//  3. 覆写 setFilter（真实实现依赖私有 _latestGroups 流，测试中不可达）。
// ---------------------------------------------------------------------------

class MockGithubRestClient extends Mock implements GithubRestClient {}

class MockAppInfoDatabase extends Mock implements AppInfoDatabase {}

class _TestDownloadManagerLogic extends DownloadManagerLogic {
  /// 测试注入的原始分组数据（setFilter 重放用）
  List<List<DownloadStatus>> baseGroups = [];

  /// deleteDownload 调用记录（spy）
  final deleted = <DownloadStatus>[];

  @override
  void onReady() {
    // 不订阅真实数据库（downloadStatusDatabase），数据由测试手动注入
  }

  /// 注入分组数据并按当前筛选重建列表
  void seed(List<List<DownloadStatus>> groups) {
    baseGroups = List.of(groups);
    downloadGroups.value = _applyFilter(baseGroups, currentFilter.value);
  }

  @override
  void setFilter(DownloadFilter filter) {
    currentFilter.value = filter;
    // 与生产 _applyFilter 语义一致：基于原始分组重放（matchesFilter 已有单测覆盖）
    downloadGroups.value = _applyFilter(baseGroups, filter);
  }

  List<List<DownloadStatus>> _applyFilter(
    List<List<DownloadStatus>> groups,
    DownloadFilter filter,
  ) {
    if (filter == DownloadFilter.all) return groups;
    return groups
        .map((group) =>
            group.where((item) => matchesFilter(item, filter)).toList())
        .where((group) => group.isNotEmpty)
        .toList();
  }

  @override
  Future<void> deleteDownload(DownloadStatus downStatus) async {
    deleted.add(downStatus);
  }
}

// ---------------------------------------------------------------------------
// 工具函数
// ---------------------------------------------------------------------------

/// 构造 DownloadStatus 后直接赋 status 字段：
/// 构造器会把 LOADING 重置为 READY（同 download_status_utils_test.dart 做法）。
DownloadStatus _item(
  int status, {
  required String appId,
  String appName = '测试应用',
  String version = '1.0.0',
  String fileName = 'app.apk',
}) {
  final item = DownloadStatus(
    appId,
    appName,
    version,
    fileName,
    'https://example.com/$fileName',
    '/data/media/0/Download/$fileName',
  );
  item.status = status;
  return item;
}

/// 放大测试视口，确保多卡片全部进入 ListView 构建范围
void _useTallView(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

void main() {
  late _TestDownloadManagerLogic logic;

  // 注意：不在 setUpAll 做 sqfliteFfiInit——widget 测试环境（flutter_test binding
  // 已初始化）下 ffi isolate 模式会与测试框架挂起；下载数据库由逻辑构造时
  // 懒打开（依赖宿主 libsqlite3，运行需 LD_LIBRARY_PATH 提供 .so）
  setUp(() {
    Get.reset();

    // 1. 满足 DownloadManagerLogic 构造期依赖：
    //    GithubRequestMix.githubApi = Get.find<GithubRestClient>()
    //    appInfoDB = "gstore".repoDB.db = Get.find<DbManager>()._getDB("gstore")
    Get.put<GithubRestClient>(MockGithubRestClient());
    final dbManager = DbManager();
    Get.put<DbManager>(dbManager);
    dbManager.dbRepositroies['gstore'] = DBRepository(
      'gstore',
      'sunO2',
      'GStore-Repositorys',
      MockAppInfoDatabase(),
    );

    // 2. 预注册测试子类（view 内 Get.put(DownloadManagerLogic()) 命中已注册实例）
    logic = _TestDownloadManagerLogic();
    Get.put<DownloadManagerLogic>(logic);
  });

  tearDown(() {
    Get.reset();
  });

  /// 渲染下载管理页。用固定时长 pump 而非 pumpAndSettle：
  /// 卡片图标 placeholder（AppLoading）是无限循环动画，pumpAndSettle 会超时。
  Future<void> pumpPage(WidgetTester tester) async {
    await tester.pumpWidget(const GetMaterialApp(home: DownloadManager()));
    // 让 CachedNetworkImage 空 URL 加载失败 → 展示 errorWidget（停掉占位动画）
    await tester.pump();
  }

  testWidgets('空状态：无下载记录时显示「暂无下载记录」', (tester) async {
    logic.seed([]);

    await pumpPage(tester);

    expect(find.text('暂无下载记录'), findsOneWidget);
    expect(find.text('下载的应用会显示在这里'), findsOneWidget);
    // 筛选 chips 仍然渲染
    expect(find.byType(FilterChip), findsNWidgets(4));
    expect(tester.takeException(), isNull);
  });

  testWidgets('主操作按钮按状态渲染：LOADING→暂停/READY→继续/ERROR→重试/SUCCESS+.apk→安装',
      (tester) async {
    _useTallView(tester);

    logic.seed([
      [
        _item(DownloadStatus.DOWNLOAD_LOADING,
            appId: 'com.example.loading', fileName: 'loading.apk'),
      ],
      [
        _item(DownloadStatus.DOWNLOAD_READY,
            appId: 'com.example.ready', fileName: 'ready.apk'),
      ],
      [
        _item(DownloadStatus.DOWNLOAD_ERROR,
            appId: 'com.example.error', fileName: 'error.apk'),
      ],
      [
        _item(DownloadStatus.DOWNLOAD_SUCCESS,
            appId: 'com.example.success', fileName: 'success.apk'),
      ],
    ]);

    await pumpPage(tester);

    expect(find.text('暂停'), findsOneWidget);
    expect(find.text('继续'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    expect(find.text('安装'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('删除确认：点删除图标弹出确认框，确认后调用 deleteDownload', (tester) async {
    final item = _item(DownloadStatus.DOWNLOAD_READY,
        appId: 'com.example.del', fileName: 'del.apk');
    logic.seed([
      [item],
    ]);

    await pumpPage(tester);

    // 点击行尾删除图标
    await tester.tap(find.byTooltip('删除'));
    await tester.pump(const Duration(milliseconds: 300));

    // AppDialogs 风格确认框出现
    expect(find.text('删除下载'), findsOneWidget);
    expect(find.textContaining('此操作不可恢复'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '删除'), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);

    // 确认删除
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    expect(logic.deleted, [item]);
    expect(find.text('删除下载'), findsNothing);
  });

  testWidgets('Dismissible 滑动触发删除确认：取消不删除，确认后删除', (tester) async {
    final item = _item(DownloadStatus.DOWNLOAD_SUCCESS,
        appId: 'com.example.swipe', fileName: 'swipe.apk');
    logic.seed([
      [item],
    ]);

    await pumpPage(tester);

    // 左滑 → confirmDismiss 弹出确认框（timedDrag 慢速拖动，确保被 Dismissible 识别）
    await tester.timedDrag(
      find.byType(Dismissible),
      const Offset(-500, 0),
      const Duration(milliseconds: 500),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('删除下载'), findsOneWidget);

    // 取消 → 不删除，卡片弹回
    await tester.tap(find.text('取消'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    expect(logic.deleted, isEmpty);

    // 再次左滑 → 确认删除 → onDismissed 调用 deleteDownload
    await tester.timedDrag(
      find.byType(Dismissible),
      const Offset(-500, 0),
      const Duration(milliseconds: 500),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('删除下载'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    expect(logic.deleted, [item]);
  });

  testWidgets('筛选 chips 渲染（全部/下载中/已完成/失败）且切换生效', (tester) async {
    _useTallView(tester);

    logic.seed([
      [
        _item(DownloadStatus.DOWNLOAD_ERROR,
            appId: 'com.example.fail', appName: '失败应用', fileName: 'f.apk'),
      ],
      [
        _item(DownloadStatus.DOWNLOAD_SUCCESS,
            appId: 'com.example.done', appName: '完成应用', fileName: 's.apk'),
      ],
      [
        _item(DownloadStatus.DOWNLOAD_LOADING,
            appId: 'com.example.dling', appName: '下载应用', fileName: 'l.apk'),
      ],
    ]);

    await pumpPage(tester);

    // 4 个筛选 chip 全部渲染
    expect(find.byType(FilterChip), findsNWidgets(4));
    for (final label in ['全部', '下载中', '已完成', '失败']) {
      expect(find.widgetWithText(FilterChip, label), findsOneWidget);
    }

    // 初始「全部」：三个应用都显示
    expect(find.text('失败应用'), findsOneWidget);
    expect(find.text('完成应用'), findsOneWidget);
    expect(find.text('下载应用'), findsOneWidget);

    // 切「失败」→ 仅 ERROR 项
    await tester.tap(find.widgetWithText(FilterChip, '失败'));
    await tester.pump();
    expect(find.text('失败应用'), findsOneWidget);
    expect(find.text('完成应用'), findsNothing);
    expect(find.text('下载应用'), findsNothing);

    // 切「已完成」→ 仅 SUCCESS 项
    await tester.tap(find.widgetWithText(FilterChip, '已完成'));
    await tester.pump();
    expect(find.text('完成应用'), findsOneWidget);
    expect(find.text('失败应用'), findsNothing);
    expect(find.text('下载应用'), findsNothing);

    // 切「全部」→ 全部恢复
    await tester.tap(find.widgetWithText(FilterChip, '全部'));
    await tester.pump();
    expect(find.text('失败应用'), findsOneWidget);
    expect(find.text('完成应用'), findsOneWidget);
    expect(find.text('下载应用'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('卡片显示应用名/版本/状态徽标', (tester) async {
    final item = _item(
      DownloadStatus.DOWNLOAD_LOADING,
      appId: 'com.example.card',
      appName: '示例应用',
      version: '2.3.4',
      fileName: 'card.apk',
    );
    logic.seed([
      [item],
    ]);

    await pumpPage(tester);

    // 应用名与版本
    expect(find.text('示例应用'), findsOneWidget);
    expect(find.text('2.3.4'), findsOneWidget);

    // 状态徽标渲染在卡片内（卡片头 + 文件行各一个「下载中」徽标）
    final inCard = find.descendant(
      of: find.byType(AppCard),
      matching: find.text('下载中'),
    );
    expect(inCard, findsNWidgets(2));
    // 全局另有 1 个「下载中」筛选 chip
    expect(find.text('下载中'), findsNWidgets(3));
    expect(tester.takeException(), isNull);
  });
}
