import 'dart:ffi';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/aggregate/AppAddedDatabase.dart';
import 'package:gstore/core/aggregate/AppAggregatorManager.dart';
import 'package:gstore/core/channel/ChannelManager.dart';
import 'package:gstore/core/channel/IChannel.dart';
import 'package:gstore/core/channel/model/AppUpdateCheckResult.dart';
import 'package:gstore/core/channel/model/ChannelInfo.dart';
import 'package:gstore/core/channel/model/ChannelResult.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/model/AppSummary.dart';
import 'package:gstore/core/model/IDetailInfo.dart';
import 'package:gstore/db/apps/AppInfo.dart' as db;
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/open.dart';

/// 记录被查询应用 ID 的假渠道（getAppInfo 延迟 10ms）
///
/// - 分页正确性证据：getAggregatedAppsPage(offset, limit) 只应对
///   [offset, offset+limit) 的应用发起渠道查询（fetchedIds 恰好等于该切片）
/// - 分页追加连续性：连续两页 fetchedIds 拼接 = 全部应用，且无重复
class PaginationFakeChannel extends IChannel {
  final ChannelType type;
  final Duration delay;

  /// 被查询过的应用 ID（用于断言分页切片）
  final List<String> fetchedIds = [];

  PaginationFakeChannel(
    this.type, {
    this.delay = const Duration(milliseconds: 10),
  });

  @override
  ChannelInfo get info => ChannelInfo(
        type: type,
        name: type.code,
        description: '',
        priority: 1,
        enabled: true,
      );

  @override
  Future<ChannelResult<AppSummary?>> getAppInfo(String appId,
      {bool forceRefresh = false}) async {
    fetchedIds.add(appId);
    await Future.delayed(delay);
    return ChannelResult.success(
      data: AppSummary(
        appId: appId,
        packageName: null,
        name: 'App $appId',
        user: '',
        repositories: '',
        icon: '',
        des: '描述',
        category: null,
      ),
      from: type,
    );
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
  Future<ChannelResult<void>> addApp(AppSummary app) async =>
      ChannelResult.success(data: null, from: type);

  @override
  Widget? getAddAppWidget(BuildContext context, Function(AppSummary) onAppAdded,
          {VoidCallback? onAppSaved}) =>
      null;

  @override
  Future<ChannelResult<List<AppSummary>>> getAllApps(
          {bool forceRefresh = false}) async =>
      ChannelResult.success(data: [], from: type);

  @override
  Future<ChannelResult<IDetailInfo>> getAppDetail(String appId,
          {bool forceRefresh = false}) async =>
      throw UnimplementedError();

  @override
  Future<ChannelResult<AppUpdateCheckResult>> checkAppUpdate(
          String appId) async =>
      throw UnimplementedError();

  @override
  Future<ChannelResult<void>> removeApp(String appId) async =>
      ChannelResult.success(data: null, from: type);

  @override
  Future<ChannelResult<List<AppSummary>>> searchApps(String keyword,
          {bool forceRefresh = false}) async =>
      ChannelResult.success(data: [], from: type);

  @override
  Future<ChannelResult<List<AppSummary>>> searchByCategory(String categoryId,
          {bool forceRefresh = false}) async =>
      ChannelResult.success(data: [], from: type);

  @override
  Future<ChannelResult<List<db.AppCategory>>> getAllCategories(
          {bool forceRefresh = false}) async =>
      ChannelResult.success(data: [], from: type);

  @override
  Future<ChannelResult<bool>> checkUpdate() async =>
      ChannelResult.success(data: false, from: type);

  @override
  Future<ChannelResult<bool>> doUpdate(
          {Function(int current, int total)? onProgress}) async =>
      ChannelResult.success(data: true, from: type);

  @override
  Future<ChannelResult<db.AppInfoConfig?>> getConfig(
          {bool forceRefresh = false}) async =>
      ChannelResult.success(data: null, from: type);

  @override
  Future<void> clearCache() async {}

  @override
  Future<int> getCacheSize() async => 0;

  @override
  Future<void> dispose() async {}
}

/// getAggregatedAppsPage 分页加载测试
///
/// 验证：
/// - 每页只对 [offset, offset+limit) 的应用发起渠道查询（读取耗时分摊到每次滚动）
/// - 分页返回 (本页应用, 总数)；最后一页尾切片边界正确
/// - 连续两页拼接 = 完整列表且顺序与 addedApps（addTime 倒序）一致、无重复
/// - offset 越界 / limit<=0 返回空页 + 总数
void main() {
  late AppAddedDatabase db;
  late PaginationFakeChannel githubChannel;

  setUpAll(() {
    open.overrideFor(OperatingSystem.linux,
        () => DynamicLibrary.open('libsqlite3.so.0'));
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});

    // 独享 DB 文件（':memory:' 会被多个测试 isolate 映射为公共文件互相踩踏）
    final dbFile = p.join(
        await databaseFactory.getDatabasesPath(), 'aggregator_pagination_test.db');
    await databaseFactory.deleteDatabase(dbFile);

    db = await AppAddedDatabase.create(dbPath: dbFile);
    await db.addedAppDao.clearAll();
    final manager = AppAggregatorManager.instance;
    manager.debugDatabase = db;
    manager.debugChannelManager = ChannelManager.instance;

    githubChannel = PaginationFakeChannel(ChannelType.github);
    ChannelManager.instance.registerChannel(githubChannel);
  });

  tearDown(() async {
    await db.close();
  });

  Future<void> seedApps(int total) async {
    final base = DateTime.now().millisecondsSinceEpoch;
    for (var i = 0; i < total; i++) {
      await db.addedAppDao.insertApp(AddedAppInfo(
        channelId: 'github',
        appId: 'app-$i',
        addTime: base - i,
      ));
    }
  }

  test('32 条应用：第一页只取 [0,10)，渠道查询恰好命中该切片，total=32', () async {
    const total = 32;
    await seedApps(total);
    final manager = AppAggregatorManager.instance;

    final (apps, count) = await manager.getAggregatedAppsPage(
      offset: 0,
      limit: 10,
    );

    expect(count, total, reason: '总数应为全部已添加应用数');
    expect(apps, hasLength(10));
    // 只对 [0,10) 发起渠道查询（关键：不一次性读取全部）
    expect(githubChannel.fetchedIds, hasLength(10));
    for (var i = 0; i < 10; i++) {
      expect(githubChannel.fetchedIds, contains('app-$i'));
      expect(apps[i].addedAppInfo.appId, 'app-$i',
          reason: '顺序与 addedApps（addTime 倒序）一致');
    }
  });

  test('第二页从 offset=10 续取，两页拼接 = 完整 32 条且无重复', () async {
    const total = 32;
    await seedApps(total);
    final manager = AppAggregatorManager.instance;

    final (page1, _) =
        await manager.getAggregatedAppsPage(offset: 0, limit: 10);
    // 第二页只应新增查询 [10,20)，fetchedIds 增量恰好 10 条
    final beforeSecondPage = githubChannel.fetchedIds.length;
    final (page2, count2) =
        await manager.getAggregatedAppsPage(offset: 10, limit: 10);

    expect(count2, total);
    expect(page2, hasLength(10));
    expect(githubChannel.fetchedIds.length - beforeSecondPage, 10,
        reason: '第二页只查询 10 个应用（增量非全量）');
    for (var i = 10; i < 20; i++) {
      expect(githubChannel.fetchedIds, contains('app-$i'));
    }

    final concatenated = [...page1, ...page2].map((e) => e.addedAppInfo.appId).toList();
    expect(concatenated, hasLength(20));
    expect(concatenated.toSet(), hasLength(20), reason: '两页无重复');
    for (var i = 0; i < 20; i++) {
      expect(concatenated[i], 'app-$i', reason: '拼接后顺序连续');
    }
  });

  test('最后一页尾切片（26..32）：只取剩余 6 条，渠道查询恰好命中', () async {
    const total = 32;
    await seedApps(total);
    final manager = AppAggregatorManager.instance;

    final (apps, count) = await manager.getAggregatedAppsPage(
      offset: 26,
      limit: 10,
    );

    expect(count, total);
    expect(apps, hasLength(6), reason: '尾切片应为剩余 6 条');
    for (var i = 26; i < 32; i++) {
      expect(githubChannel.fetchedIds, contains('app-$i'));
    }
  });

  test('offset 越界 / limit<=0：返回空页 + 总数（不发起渠道查询）', () async {
    const total = 8;
    await seedApps(total);
    final manager = AppAggregatorManager.instance;

    final (beyond, count1) =
        await manager.getAggregatedAppsPage(offset: 100, limit: 10);
    expect(beyond, isEmpty);
    expect(count1, total);

    final (noLimit, count2) =
        await manager.getAggregatedAppsPage(offset: 0, limit: 0);
    expect(noLimit, isEmpty);
    expect(count2, total);

    final queried = githubChannel.fetchedIds.length;
    expect(queried, 0, reason: '越界/非法分页不应触发渠道查询');
  });
}