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

/// 返回固定渠道分类 ['工具'] 的假渠道（getAppInfo 立即返回）
class FakeTagsChannel implements IChannel {
  final ChannelType type;

  FakeTagsChannel(this.type);

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
    return ChannelResult.success(
      data: AppSummary(
        appId: appId,
        packageName: null,
        name: 'App $appId',
        user: '',
        repositories: '',
        icon: '',
        des: '描述',
        category: ['工具'], // 渠道自带分类
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

/// canonicalAppId 返回与入参 appId 不同的规范化 ID 的假渠道
/// （模拟 GitHub 收录场景：raw 'owner/repo' → 真实包名 'com.example.app'，
///  与 discovery 页 showTagPickerForApp 修复后的取 key 路径一致）
class FakeCanonicalizingTagsChannel extends FakeTagsChannel {
  FakeCanonicalizingTagsChannel(super.type);

  @override
  Future<String> canonicalAppId(AppSummary appInfo) async =>
      'com.example.app';
}

/// getAggregatedApps 合并用户标签到分类测试
///
/// 验证（v5 用户标签系统聚合侧）：
/// - manager.setTags 写入后，getAggregatedApps 返回的 appInfo.category
///   同时包含渠道自带分类（FakeTagsChannel → ['工具']）与用户标签（['我的标签']），去重合并
/// - 无标签应用分类保持渠道原值（不受 tagsIndex 影响）
/// - 用户标签与渠道分类重叠时去重（不产生重复项）
void main() {
  late AppAddedDatabase db;
  late AppAggregatorManager manager;

  setUpAll(() {
    // Linux 仅有 libsqlite3.so.0（无 .so 符号链接），显式指定动态库
    open.overrideFor(OperatingSystem.linux,
        () => DynamicLibrary.open('libsqlite3.so.0'));
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});

    // 注意：不使用共享的 inMemoryDatabasePath（':memory:'）——sqflite_common_ffi
    // 将其映射为 .dart_tool 下公共文件，多个测试文件并行 isolate 删除/重建会
    // 互相踩踏（详见 aggregator_parallel_test 的 readonly 竞态）；本文件独享
    // 一个文件路径，delete+create 只影响本文件，保证用例隔离。
    final dbFile = p.join(
        await databaseFactory.getDatabasesPath(), 'aggregator_tags_test.db');
    await databaseFactory.deleteDatabase(dbFile);

    db = await AppAddedDatabase.create(dbPath: dbFile);
    addTearDown(db.close);

    manager = AppAggregatorManager.instance;
    manager.debugDatabase = db;
    manager.debugChannelManager = ChannelManager.instance;

    ChannelManager.instance.registerChannel(FakeTagsChannel(ChannelType.github));
  });

  test('setTags 后 getAggregatedApps：分类 = 渠道分类 ∪ 用户标签（去重）', () async {
    // 注入一条 addedApp（channelId=github / appId=com.tags）
    await db.addedAppDao.insertApp(AddedAppInfo(
      channelId: 'github',
      appId: 'com.tags',
      addTime: 1000,
    ));

    // 打用户标签
    await manager.setTags(
      channel: ChannelType.github,
      appId: 'com.tags',
      tags: ['我的标签'],
    );

    final result = await manager.getAggregatedApps();

    expect(result, hasLength(1));
    final info = result.single;
    expect(info.addedAppInfo.appId, 'com.tags');
    expect(info.appInfo.category, containsAll(['工具', '我的标签']),
        reason: '渠道分类与用户标签必须合并展示');
    expect(info.appInfo.category!.toSet().length, info.appInfo.category!.length,
        reason: '合并结果无重复项');
    expect(info.isFromCache, isFalse, reason: '渠道查询成功，非缓存占位');
  });

  test('setTags 整体替换语义：新标签集合覆盖旧集合', () async {
    await db.addedAppDao.insertApp(AddedAppInfo(
      channelId: 'github',
      appId: 'com.tags',
      addTime: 1000,
    ));

    await manager.setTags(
      channel: ChannelType.github,
      appId: 'com.tags',
      tags: ['a', 'b'],
    );
    await manager.setTags(
      channel: ChannelType.github,
      appId: 'com.tags',
      tags: ['c'],
    );

    final result = await manager.getAggregatedApps();
    expect(result.single.appInfo.category, containsAll(['工具', 'c']),
        reason: 'setTags 替换后仅保留新标签');
    expect(result.single.appInfo.category, isNot(contains('a')),
        reason: '被替换的旧标签必须移除');
    expect(result.single.appInfo.category, isNot(contains('b')));
  });

  test('无用户标签应用：分类保持渠道原值', () async {
    await db.addedAppDao.insertApp(AddedAppInfo(
      channelId: 'github',
      appId: 'com.noTags',
      addTime: 1000,
    ));

    final result = await manager.getAggregatedApps();

    expect(result, hasLength(1));
    expect(result.single.appInfo.category, ['工具'],
        reason: '无标签时分类为渠道原值，不注入空标签');
  });

  test('用户标签与渠道分类重叠：合并去重不重复', () async {
    await db.addedAppDao.insertApp(AddedAppInfo(
      channelId: 'github',
      appId: 'com.tags',
      addTime: 1000,
    ));

    // 用户标签与渠道分类 ['工具'] 重叠
    await manager.setTags(
      channel: ChannelType.github,
      appId: 'com.tags',
      tags: ['工具', '效率'],
    );

    final result = await manager.getAggregatedApps();
    final category = result.single.appInfo.category!;
    expect(category, containsAll(['工具', '效率']));
    expect(category.where((c) => c == '工具'), hasLength(1),
        reason: '重叠分类只保留一份');
  });

  test('removeApp 联动清理：移除应用后其标签一并删除', () async {
    await db.addedAppDao.insertApp(AddedAppInfo(
      channelId: 'github',
      appId: 'com.tags',
      addTime: 1000,
    ));
    await manager.setTags(
      channel: ChannelType.github,
      appId: 'com.tags',
      tags: ['我的标签'],
    );

    await manager.removeApp(channel: ChannelType.github, appId: 'com.tags');

    expect(await manager.getTags(channel: ChannelType.github, appId: 'com.tags'),
        isEmpty, reason: '移除应用必须联动清理用户标签');
    expect(await manager.getAllTagsIndex(), isEmpty);
  });

  test('发现页标签保存：canonical appId 作 key 才能匹配聚合库（raw appId 作 key 丢失）',
      () async {
    // 覆盖注册：GitHub 渠道换成"规范化"假渠道（canonicalAppId 返回真实包名），
    // 模拟发现页 showTagPickerForApp 修复后的调用链（addApp 与 setTags 同 key）
    ChannelManager.instance
        .registerChannel(FakeCanonicalizingTagsChannel(ChannelType.github));

    // 1) 发现页添加应用：聚合库落 key = canonicalAppId('owner/repo') = 'com.example.app'
    await manager.addApp(
      channel: ChannelType.github,
      appInfo: AppSummary(
        appId: 'owner/repo',
        packageName: null,
        name: 'Demo App',
        user: 'owner',
        repositories: 'owner/repo',
        icon: '',
        des: '',
        category: null,
      ),
    );
    expect(await db.addedAppDao.getApp('github', 'com.example.app'), isNotNull,
        reason: 'addApp 必须以规范化 appId 落库');
    expect(await db.addedAppDao.getApp('github', 'owner/repo'), isNull,
        reason: 'raw appId 不应出现在聚合库');

    // 2) 修复后的发现页逻辑：用 canonicalId 保存标签 → key 与聚合库条目一致
    await manager.setTags(
      channel: ChannelType.github,
      appId: 'com.example.app',
      tags: ['我的标签'],
    );

    // 3) 首页聚合：canonical key 的标签必须合并进分类（证明 key 匹配）
    final result = await manager.getAggregatedApps();
    expect(result, hasLength(1));
    final info = result.single;
    expect(info.addedAppInfo.appId, 'com.example.app',
        reason: '聚合库条目 appId 为规范化后的真实包名');
    expect(info.appInfo.category, contains('我的标签'),
        reason: 'canonical appId 作 key 保存的标签必须出现在首页分类筛选');

    // 4) 反证：raw appId（owner/repo）作 key 保存 → 标签丢失
    //    （文档化修复必要性：旧代码用 raw appId 作 key 匹配不到聚合库）
    await manager.setTags(
      channel: ChannelType.github,
      appId: 'owner/repo',
      tags: ['游戏'],
    );
    final index = await manager.getAllTagsIndex();
    expect(index['github:owner/repo'], contains('游戏'),
        reason: 'raw key 标签确实写入了独立条目（与 canonical key 互不相通）');
    final result2 = await manager.getAggregatedApps();
    expect(result2.single.appInfo.category, isNot(contains('游戏')),
        reason: 'raw appId 作 key 匹配不到聚合库条目 → 首页分类看不到该标签（修复点）');
  });
}
