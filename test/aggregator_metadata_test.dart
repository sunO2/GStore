import 'dart:convert';
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
import 'package:gstore/core/data/metadata_repository.dart';
import 'package:gstore/core/model/AppSummary.dart';
import 'package:gstore/db/apps/AppInfo.dart' as db;
import 'package:gstore/core/model/IDetailInfo.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/open.dart';

/// 可配置 canonicalAppId 的假渠道（验证"渠道自报 appId + 统一添加入口"）
class FakeChannel extends IChannel {
  final ChannelType type;
  final String Function(AppSummary) canonical;

  /// 记录 addApp 调用（统一添加入口验证）
  final List<AppSummary> addedApps = [];
  bool failAddApp = false;

  FakeChannel(this.type, this.canonical);

  @override
  ChannelInfo get info => ChannelInfo(
        type: type,
        name: type.code,
        description: '',
        priority: 1,
        enabled: true,
      );

  @override
  Future<String> canonicalAppId(AppSummary appInfo) async => canonical(appInfo);

  @override
  Future<ChannelResult<void>> addApp(AppSummary app) async {
    if (failAddApp) throw Exception('addApp failed');
    addedApps.add(app);
    return ChannelResult.success(data: null, from: type);
  }

  @override
  Future<void> initialize() async {}

  @override
  bool get isInitialized => true;

  @override
  Future<bool> checkAvailable() async => true;

  @override
  Widget? getAddAppWidget(BuildContext context, Function(AppSummary) onAppAdded,
          {VoidCallback? onAppSaved}) =>
      null;

  @override
  Future<ChannelResult<List<AppSummary>>> getAllApps({bool forceRefresh = false}) async =>
      ChannelResult.success(data: [], from: type);

  @override
  Future<ChannelResult<AppSummary?>> getAppInfo(String appId,
          {bool forceRefresh = false}) async =>
      ChannelResult.success(data: null, from: type);

  @override
  Future<ChannelResult<IDetailInfo>> getAppDetail(String appId,
          {bool forceRefresh = false}) async =>
      throw UnimplementedError();

  @override
  Future<ChannelResult<AppUpdateCheckResult>> checkAppUpdate(String appId) async =>
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
  Future<ChannelResult<bool>> doUpdate({Function(int current, int total)? onProgress}) async =>
      ChannelResult.success(data: true, from: type);

  @override
  Future<ChannelResult<db.AppInfoConfig?>> getConfig({bool forceRefresh = false}) async =>
      ChannelResult.success(data: null, from: type);

  @override
  Future<void> clearCache() async {}

  @override
  Future<int> getCacheSize() async => 0;

  @override
  Future<void> dispose() async {}
}

/// AppAggregatorManager 添加应用流程测试
///
/// 验证架构：
/// - appId 形态由渠道自报（IChannel.canonicalAppId），聚合层无渠道特判
/// - 统一添加入口：聚合添加时调用渠道 addApp 落渠道库（失败不阻断）
/// - 聚合库只存引用字段（channelId/appId/addTime/sortOrder/isEnabled）
void main() {
  late AppAddedDatabase db;
  late FakeChannel githubChannel;
  late FakeChannel localDbChannel;

  setUpAll(() {
    // Linux 系统仅有 libsqlite3.so.0（无 .so 符号链接），显式指定动态库
    open.overrideFor(OperatingSystem.linux,
        () => DynamicLibrary.open('libsqlite3.so.0'));
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await MetadataRepository.instance.clearCache();

    // 注意：sqflite_common_ffi 对 ':memory:' 按路径复用同一实例，
    // 必须清空残留数据保证用例隔离
    db = await AppAddedDatabase.create(dbPath: inMemoryDatabasePath);
    await db.addedAppDao.clearAll();
    final manager = AppAggregatorManager.instance;
    manager.debugDatabase = db;
    manager.debugChannelManager = ChannelManager.instance;

    // 注册假渠道：canonicalAppId 默认原样返回（未收录行为）
    githubChannel = FakeChannel(ChannelType.github, (app) => app.appId);
    localDbChannel = FakeChannel(ChannelType.localDb, (app) => app.appId);
    ChannelManager.instance.registerChannel(githubChannel);
    ChannelManager.instance.registerChannel(localDbChannel);
  });

  tearDown(() async {
    await db.close();
  });

  /// GitHub 搜索结果：appId 为 owner/repo 占位，图标为 owner 头像
  AppSummary githubSearchResult(String appId, {String user = '', String repo = ''}) {
    final parts = appId.split('/');
    return AppSummary(
      appId: appId,
      packageName: null,
      name: parts.length == 2 ? parts[1] : appId,
      user: user.isNotEmpty ? user : (parts.isNotEmpty ? parts[0] : ''),
      repositories: repo.isNotEmpty ? repo : (parts.length == 2 ? parts[1] : ''),
      icon: 'https://avatars.githubusercontent.com/u/1', // 临时占位（owner 头像）
      des: '描述',
      category: null,
    );
  }

  /// LocalDb 搜索结果：appId 为包名，user/repositories 是 GitHub 仓库
  AppSummary localDbResult(String packageName, String user, String repo) {
    return AppSummary(
      appId: packageName,
      packageName: packageName,
      name: repo,
      user: user,
      repositories: repo,
      icon: '',
      des: '描述',
      category: null,
    );
  }

  group('GitHub 渠道添加（appId 由渠道自报）', () {
    test('渠道 canonicalAppId 返回真实包名：聚合 appId 用包名，且统一调用渠道 addApp', () async {
      // 模拟 GitHub 渠道 metadata 已收录：canonicalAppId 返回真实包名
      githubChannel = FakeChannel(
          ChannelType.github, (app) => 'com.termux');
      ChannelManager.instance.registerChannel(githubChannel);

      final manager = AppAggregatorManager.instance;
      await manager.addApp(
        channel: ChannelType.github,
        appInfo: githubSearchResult('termux/termux-app'),
      );

      final apps = await db.addedAppDao.getAllAddedApps();
      expect(apps, hasLength(1));
      final app = apps.first;
      // 关键断言：appId 使用渠道自报的真实包名
      expect(app.appId, 'com.termux');
      expect(app.channelId, 'github');
      expect(app.isEnabled, isTrue);
      expect(app.sortOrder, 0);
      expect(app.addTime, greaterThan(0));

      // 统一添加入口：渠道 addApp 被调用，且收到的是规范化后的 appId
      expect(githubChannel.addedApps, hasLength(1),
          reason: '聚合添加应统一调用渠道 addApp 落渠道库');
      expect(githubChannel.addedApps.first.appId, 'com.termux');
    });

    test('渠道 canonicalAppId 返回原样（未收录）：appId 保持占位 owner/repo', () async {
      final manager = AppAggregatorManager.instance;
      await manager.addApp(
        channel: ChannelType.github,
        appInfo: githubSearchResult('unknown/app-unknown'),
      );

      final apps = await db.addedAppDao.getAllAddedApps();
      expect(apps, hasLength(1));
      expect(apps.first.appId, 'unknown/app-unknown',
          reason: '未收录时应保持占位 appId');
      expect(githubChannel.addedApps, hasLength(1));
    });

    test('渠道 addApp 失败不阻断首页添加', () async {
      githubChannel = FakeChannel(
          ChannelType.github, (app) => 'com.termux')
        ..failAddApp = true;
      ChannelManager.instance.registerChannel(githubChannel);

      final manager = AppAggregatorManager.instance;
      await manager.addApp(
        channel: ChannelType.github,
        appInfo: githubSearchResult('termux/termux-app'),
      );

      final apps = await db.addedAppDao.getAllAddedApps();
      expect(apps, hasLength(1), reason: '渠道保存失败不应影响聚合库写入');
      expect(apps.first.appId, 'com.termux');
    });

    test('渠道自报包名后重复添加：幂等（replace）', () async {
      githubChannel = FakeChannel(
          ChannelType.github, (app) => 'com.termux');
      ChannelManager.instance.registerChannel(githubChannel);

      final manager = AppAggregatorManager.instance;
      final app = githubSearchResult('termux/termux-app');
      await manager.addApp(channel: ChannelType.github, appInfo: app);
      await manager.addApp(channel: ChannelType.github, appInfo: app);

      final apps = await db.addedAppDao.getAllAddedApps();
      expect(apps, hasLength(1), reason: '同一应用重复添加应覆盖而非新增');
      expect(apps.first.appId, 'com.termux');
    });
  });

  group('LocalDb 渠道添加', () {
    test('appId 保持包名（LocalDb appId 本就是包名）', () async {
      final manager = AppAggregatorManager.instance;
      await manager.addApp(
        channel: ChannelType.localDb,
        appInfo: localDbResult('com.termux', 'termux', 'termux-app'),
      );

      final apps = await db.addedAppDao.getAllAddedApps();
      expect(apps, hasLength(1));
      expect(apps.first.appId, 'com.termux');
      expect(localDbChannel.addedApps, hasLength(1));
    });

    test('普通应用：保持原 ID', () async {
      final manager = AppAggregatorManager.instance;
      await manager.addApp(
        channel: ChannelType.localDb,
        appInfo: AppSummary(
          appId: 'com.vivo.app',
          packageName: null,
          name: 'Vivo App',
          user: '',
          repositories: '',
          icon: '',
          des: '',
          category: null,
        ),
      );

      final apps = await db.addedAppDao.getAllAddedApps();
      expect(apps, hasLength(1));
      expect(apps.first.appId, 'com.vivo.app');
    });
  });

  group('批量添加', () {
    test('混合收录/未收录：各自按渠道自报 appId', () async {
      // termux 收录 → 包名；unknown 未收录 → 占位
      githubChannel = FakeChannel(ChannelType.github, (app) {
        return app.appId == 'termux/termux-app' ? 'com.termux' : app.appId;
      });
      ChannelManager.instance.registerChannel(githubChannel);

      final manager = AppAggregatorManager.instance;
      await manager.addApps(
        channel: ChannelType.github,
        appInfos: [
          githubSearchResult('termux/termux-app'),
          githubSearchResult('unknown/app-unknown'),
        ],
      );

      final apps = await db.addedAppDao.getAllAddedApps();
      expect(apps, hasLength(2));
      final byId = {for (final a in apps) a.appId: a};
      expect(byId.containsKey('com.termux'), isTrue, reason: '收录 → 真实包名');
      expect(byId.containsKey('unknown/app-unknown'), isTrue,
          reason: '未收录 → 占位');
      expect(githubChannel.addedApps, hasLength(2),
          reason: '批量添加也应统一调用渠道 addApp');
    });
  });

  group('已添加状态与移除', () {
    test('isAppAdded / removeApp 基于引用字段工作', () async {
      final manager = AppAggregatorManager.instance;
      await manager.addApp(
        channel: ChannelType.github,
        appInfo: githubSearchResult('termux/termux-app'),
      );

      expect(
        await manager.isAppAdded(
            channel: ChannelType.github, appId: 'termux/termux-app'),
        isTrue,
      );
      expect(
        await manager.isAppAdded(
            channel: ChannelType.github, appId: 'com.termux'),
        isFalse,
        reason: '未收录场景 appId 为占位，包名不是引用键',
      );

      await manager.removeApp(
          channel: ChannelType.github, appId: 'termux/termux-app');
      expect(
        await manager.isAppAdded(
            channel: ChannelType.github, appId: 'termux/termux-app'),
        isFalse,
      );
    });
  });
}
