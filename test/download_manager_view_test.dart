import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/design/app_components.dart';
import 'package:gstore/core/download/model/download_task.dart';
import 'package:gstore/core/navigation/nav_key.dart';
import 'package:gstore/page/download/download_page_providers.dart';
import 'package:gstore/page/download/download_status_utils.dart';
import 'package:gstore/page/download/view.dart';

// ---------------------------------------------------------------------------
// 测试替身
//
// 页面状态经 Riverpod 注入：子类 Notifier 覆写 load()（不订阅真实 sqlite 数据库）
// 与 deleteDownload（spy），由测试直接 seed 分组数据。
// ---------------------------------------------------------------------------

class _TestDownloadNotifier extends DownloadManagerNotifier {
  /// deleteDownload 调用记录（spy）
  final deleted = <DownloadTask>[];

  /// seed 注入的数据（build() 时读，避免在 provider 挂载前写 state）
  List<List<DownloadTask>> _seedGroups = [];
  Set<int> _seedMissing = const {};

  @override
  Future<void> load() async {
    // 不订阅真实数据库（downloadTaskDatabase），数据由测试手动注入
  }

  @override
  DownloadPageState build() {
    return DownloadPageState(
      filter: DownloadFilter.all,
      latestGroups: List.of(_seedGroups),
      groups: List.of(_seedGroups),
      missingFileIds: _seedMissing,
    );
  }

  /// 注入分组数据与缺失文件标记（初始筛选为「全部」）
  void seed(
    List<List<DownloadTask>> groups, {
    Set<int> missing = const {},
  }) {
    _seedGroups = List.of(groups);
    _seedMissing = missing;
  }

  @override
  Future<void> deleteDownload(DownloadTask downStatus) async {
    deleted.add(downStatus);
  }
}

// ---------------------------------------------------------------------------
// 工具函数
// ---------------------------------------------------------------------------

/// 构造 DownloadTask（新管线状态枚举直接指定）。
/// 同组的多个文件需显式传 [id] 区分，避免 key 冲突。
DownloadTask _item(
  DownloadStatusEnum status, {
  required String appId,
  int? id,
  String appName = '测试应用',
  String version = '1.0.0',
  String fileName = 'app.apk',
  String? downloadUrl,
  int total = 1000,
  int received = 500,
  int speedBps = 0,
  int? etaSec,
}) {
  return DownloadTask(
    id: id ?? appId.hashCode,
    appId: appId,
    appName: appName,
    version: version,
    fileName: fileName,
    url: downloadUrl ?? 'https://example.com/$fileName',
    filePath: '/data/media/0/Download/$fileName',
    total: total,
    received: received,
    status: status,
    speedBps: speedBps,
    etaSec: etaSec,
    error: null,
    segments: null,
    createdAt: DateTime.now(),
    updatedAt: DateTime.now(),
  );
}

/// 放大测试视口，确保多卡片全部进入 ListView 构建范围
void _useTallView(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

void main() {
  late _TestDownloadNotifier notifier;

  setUp(() {
    notifier = _TestDownloadNotifier();
  });

  /// 渲染下载管理页。用固定时长 pump 而非 pumpAndSettle：
  /// 卡片图标 placeholder（AppLoading）是无限循环动画，pumpAndSettle 会超时。
  Future<void> pumpPage(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          downloadManagerProvider.overrideWith(() => notifier),
        ],
        // navigatorKey 挂全局 key：AppDialogs 生产通道（非 GetX 回退）可弹框
        child: MaterialApp(
          navigatorKey: appNavigatorKey,
          home: const DownloadManager(),
        ),
      ),
    );
    // 让 CachedNetworkImage 空 URL 加载失败 → 展示 errorWidget（停掉占位动画）
    await tester.pump();
  }

  testWidgets('空状态：无下载记录时显示「暂无下载记录」', (tester) async {
    notifier.seed([]);

    await pumpPage(tester);

    expect(find.text('暂无下载记录'), findsOneWidget);
    expect(find.text('下载的应用会显示在这里'), findsOneWidget);
    // 筛选 chips 仍然渲染
    expect(find.byType(FilterChip), findsNWidgets(4));
    expect(tester.takeException(), isNull);
  });

  testWidgets('主操作按钮按状态渲染：LOADING→暂停/READY→继续/ERROR→重试/SUCCESS+.apk→安装/QUEUED→取消',
      (tester) async {
    _useTallView(tester);

    notifier.seed([
      [
        _item(DownloadStatusEnum.downloading,
            appId: 'com.example.loading', fileName: 'loading.apk'),
      ],
      [
        _item(DownloadStatusEnum.paused,
            appId: 'com.example.ready', fileName: 'ready.apk'),
      ],
      [
        _item(DownloadStatusEnum.failed,
            appId: 'com.example.error', fileName: 'error.apk'),
      ],
      [
        _item(DownloadStatusEnum.completed,
            appId: 'com.example.success', fileName: 'success.apk'),
      ],
      [
        _item(DownloadStatusEnum.queued,
            appId: 'com.example.queued', fileName: 'queued.apk'),
      ],
    ]);

    await pumpPage(tester);

    expect(find.text('暂停'), findsOneWidget);
    expect(find.text('继续'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    expect(find.text('安装'), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('QUEUED 状态：徽标显示「排队中」，操作按钮显示「取消」', (tester) async {
    _useTallView(tester);

    notifier.seed([
      [
        _item(DownloadStatusEnum.queued,
            appId: 'com.example.queued', fileName: 'queued.apk'),
      ],
    ]);

    await pumpPage(tester);

    // 状态徽标
    expect(find.text('排队中'), findsOneWidget);
    // 主操作按钮（cancel 映射为「取消」）
    expect(find.text('取消'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('删除确认：点删除图标弹出确认框，确认后调用 deleteDownload', (tester) async {
    final item = _item(DownloadStatusEnum.paused,
        appId: 'com.example.del', fileName: 'del.apk');
    notifier.seed([
      [item],
    ]);

    await pumpPage(tester);

    // 点击行尾删除图标
    await tester.tap(find.byTooltip('删除'));
    // 统一底部弹层入场动画：首帧启动 ticker，第二帧完成滑入（首帧仍停在屏外）
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    // AppDialogs 统一弹层风格确认框出现
    expect(find.text('删除下载'), findsOneWidget);
    expect(find.textContaining('此操作不可恢复'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '删除'), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);

    // 确认删除
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    expect(notifier.deleted, [item]);
    expect(find.text('删除下载'), findsNothing);
  });

  testWidgets('Dismissible 滑动触发删除确认：取消不删除，确认后删除', (tester) async {
    final item = _item(DownloadStatusEnum.completed,
        appId: 'com.example.swipe', fileName: 'swipe.apk');
    notifier.seed([
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
    expect(notifier.deleted, isEmpty);

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

    expect(notifier.deleted, [item]);
  });

  testWidgets('筛选 chips 渲染（全部/下载中/已完成/失败）且切换生效', (tester) async {
    _useTallView(tester);

    notifier.seed([
      [
        _item(DownloadStatusEnum.failed,
            appId: 'com.example.fail', appName: '失败应用', fileName: 'f.apk'),
      ],
      [
        _item(DownloadStatusEnum.completed,
            appId: 'com.example.done', appName: '完成应用', fileName: 's.apk'),
      ],
      [
        _item(DownloadStatusEnum.downloading,
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
      DownloadStatusEnum.downloading,
      appId: 'com.example.card',
      appName: '示例应用',
      version: '2.3.4',
      fileName: 'card.apk',
    );
    notifier.seed([
      [item],
    ]);

    await pumpPage(tester);

    // 应用名与版本
    expect(find.text('示例应用'), findsOneWidget);
    expect(find.text('2.3.4'), findsOneWidget);

    // 状态徽标仅渲染在卡片头（文件行已去掉重复徽标）
    final inCard = find.descendant(
      of: find.byType(AppCard),
      matching: find.text('下载中'),
    );
    expect(inCard, findsNWidgets(1));
    // 全局另有 1 个「下载中」筛选 chip
    expect(find.text('下载中'), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('下载信息弹窗：info 按钮显示文件名/链接/渠道，可复制链接', (tester) async {
    _useTallView(tester);

    const longFileName = 'a-very-long-download-file-name-that-would-be-truncated-in-list.apk';
    final item = _item(
      DownloadStatusEnum.completed,
      appId: 'gkd-kit/gkd',
      appName: 'GKD',
      version: '1.2.3',
      fileName: longFileName,
      downloadUrl: 'https://api.github.com/repos/gkd-kit/gkd/releases/download/v1.2.3/gkd.apk',
    );
    notifier.seed([
      [item],
    ]);

    await pumpPage(tester);

    // 点行尾 info 图标
    await tester.tap(find.byTooltip('下载信息'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    // 弹窗展示完整信息（文件名不截断；列表行 + 弹窗各一处）
    expect(find.text('下载信息'), findsOneWidget);
    expect(find.text(longFileName), findsNWidgets(2));
    expect(find.text('下载链接'), findsOneWidget);
    expect(
      find.text(
          'https://api.github.com/repos/gkd-kit/gkd/releases/download/v1.2.3/gkd.apk'),
      findsOneWidget,
    );
    // 渠道推断
    expect(find.text('来源渠道'), findsOneWidget);
    expect(find.text('GitHub'), findsOneWidget);
    // 复制按钮存在
    expect(find.byTooltip('复制链接'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('已完成但文件被外部删除：不显示安装，显示「已删除」徽标/按钮', (tester) async {
    _useTallView(tester);

    final item = _item(DownloadStatusEnum.completed,
        appId: 'com.example.missing', fileName: 'missing.apk');
    final id = item.id!;
    // 模拟文件已被（缓存管理页等）删除：missingFileIds 命中该任务
    notifier.seed([
      [item],
    ], missing: {id});

    await pumpPage(tester);

    // 不显示「安装」按钮
    expect(find.text('安装'), findsNothing);
    // 徽标（组头）与主按钮位均显示「已删除」
    expect(find.text('已删除'), findsNWidgets(2));
    // 仍保留「重新下载」入口（行尾 refresh 图标）
    expect(find.byTooltip('重新下载（清空已下分段，从 0 开始）'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('已完成且文件存在：正常显示「已完成」徽标与「安装」按钮', (tester) async {
    _useTallView(tester);

    final item = _item(DownloadStatusEnum.completed,
        appId: 'com.example.exists', fileName: 'exists.apk');
    notifier.seed([
      [item],
    ]); // 文件存在：不在缺失集合

    await pumpPage(tester);

    // 徽标为「已完成」（筛选 chip「已完成」等也会命中该文本，故用 findsWidgets）
    expect(find.text('已完成'), findsWidgets);
    expect(find.text('安装'), findsOneWidget);
    expect(find.text('已删除'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  // -------------------------------------------------------------------------
  // 多文件组：折叠/展开与聚合状态
  // -------------------------------------------------------------------------

  /// 三个文件的同组任务（一个下载中 + 两个已暂停），用于折叠态聚合展示
  List<DownloadTask> multiGroupDownloading() => [
        _item(DownloadStatusEnum.downloading,
            appId: 'com.example.multi',
            id: 1,
            fileName: 'a.apk',
            total: 1000,
            received: 500,
            speedBps: 1048576),
        _item(DownloadStatusEnum.paused,
            appId: 'com.example.multi', id: 2, fileName: 'b.apk'),
        _item(DownloadStatusEnum.paused,
            appId: 'com.example.multi',
            id: 3,
            fileName: 'c.apk',
            received: 0),
      ];

  testWidgets('多文件组默认收起：显示聚合进度/计数/合计速度，不显示文件行', (tester) async {
    _useTallView(tester);
    notifier.seed([multiGroupDownloading()]);

    await pumpPage(tester);

    // 卡片头：版本 + 文件数 + 聚合状态徽标
    expect(find.text('1.0.0 · 共 3 个文件'), findsOneWidget);
    expect(
      find.descendant(of: find.byType(AppCard), matching: find.text('下载中')),
      findsOneWidget,
    );

    // 聚合摘要：整个组一条进度条 + 合计速度 + 已完成计数 + 组级剩余时间
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.text('合计 1.0 MB/s'), findsOneWidget);
    expect(find.text('0/3 已完成'), findsOneWidget);
    expect(find.text('剩余 1s'), findsOneWidget);

    // 收起时组内文件行不渲染
    expect(find.text('a.apk'), findsNothing);
    expect(find.text('b.apk'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('多文件组收起：组内失败不会被折叠藏起来（徽标与摘要都反映失败）',
      (tester) async {
    _useTallView(tester);
    // 完成的那条排在组内第一条，旧实现（只看 items[0]）会把整组显示为「已完成」
    notifier.seed([
      [
        _item(DownloadStatusEnum.completed,
            appId: 'com.example.mixed', id: 1, fileName: 'ok.apk'),
        _item(DownloadStatusEnum.completed,
            appId: 'com.example.mixed', id: 2, fileName: 'ok2.apk'),
        _item(DownloadStatusEnum.failed,
            appId: 'com.example.mixed', id: 3, fileName: 'bad.apk'),
      ],
    ]);

    await pumpPage(tester);

    // 聚合徽标显示「失败」而不是「已完成」
    expect(
      find.descendant(of: find.byType(AppCard), matching: find.text('失败')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byType(AppCard),
        matching: find.text('已完成'),
      ),
      findsNothing,
    );

    // 摘要给出完成/失败的拆分，并提供一键重试
    expect(find.text('2 个已完成'), findsOneWidget);
    expect(find.text('1 个失败'), findsOneWidget);
    expect(find.text('重试失败'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('多文件组收起且全部完成：摘要显示总大小/渠道，并给出「安装」快捷入口',
      (tester) async {
    _useTallView(tester);
    notifier.seed([
      [
        _item(DownloadStatusEnum.completed,
            appId: 'com.example.done',
            id: 1,
            fileName: 'app.apk',
            total: 1024 * 1024,
            downloadUrl:
                'https://api.github.com/repos/x/y/releases/download/v1/app.apk'),
        _item(DownloadStatusEnum.completed,
            appId: 'com.example.done',
            id: 2,
            fileName: 'extra.obb',
            total: 1024 * 1024 * 2),
      ],
    ]);

    await pumpPage(tester);

    expect(find.text('1.0.0 · 共 2 个文件'), findsOneWidget);
    expect(find.text('3.0 MB'), findsOneWidget);
    expect(find.text('GitHub'), findsOneWidget);
    // 收起态即可安装（组内唯一 apk），无需展开
    expect(find.text('安装'), findsOneWidget);
    // 已全部完成 → 不再显示聚合进度条
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('多文件组点击卡片头展开：显示各文件行并隐藏聚合摘要', (tester) async {
    _useTallView(tester);
    notifier.seed([multiGroupDownloading()]);

    await pumpPage(tester);
    expect(find.text('a.apk'), findsNothing);

    // 点卡片头展开
    await tester.tap(find.text('1.0.0 · 共 3 个文件'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // 组内每条文件行都渲染出来
    expect(find.text('a.apk'), findsOneWidget);
    expect(find.text('b.apk'), findsOneWidget);
    expect(find.text('c.apk'), findsOneWidget);
    // 聚合摘要让位给文件行
    expect(find.text('0/3 已完成'), findsNothing);

    // 再点一次收起：回到聚合摘要
    await tester.tap(find.text('1.0.0 · 共 3 个文件'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('a.apk'), findsNothing);
    expect(find.text('0/3 已完成'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
