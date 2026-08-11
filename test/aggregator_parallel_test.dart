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
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/open.dart';

/// 记录最大并发 in-flight 计数的假渠道（getAppInfo 延迟 10ms）
///
/// - 结构性并行证据：若 getAggregatedApps 串行执行，任意时刻最多 1 个
///   getAppInfo 在飞行中（maxConcurrent == 1）；分片 Future.wait 并行后
///   maxConcurrent 必然 >= 2。
/// - throwingAppId 命中时抛异常，验证 per-app try/catch 兜底不丢条。
class FakeChannel implements IChannel {
  final ChannelType type;
  final Duration delay;

  /// 抛异常的应用 ID（对应注入的第 3 个 app，索引 2）
  final String throwingAppId;

  /// 记录到的最大并发 in-flight 数
  int maxConcurrent = 0;
  int _inFlight = 0;

  FakeChannel(
    this.type, {
    this.delay = const Duration(milliseconds: 10),
    required this.throwingAppId,
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
    _inFlight++;
    if (_inFlight > maxConcurrent) maxConcurrent = _inFlight;
    try {
      await Future.delayed(delay);
      if (appId == throwingAppId) {
        throw Exception('模拟渠道异常: $appId');
      }
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
    } finally {
      _inFlight--;
    }
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

/// getAggregatedApps 分片并行化测试
///
/// 验证（todo 4 / A3）：
/// - 分片 Future.wait（片大小 8）带来结构性并发：max in-flight >= 2
/// - 结果按输入索引回填、跳过 null 压缩：顺序与 addedApps（addTime 倒序）一致
/// - per-app try/catch 兜底：单 app 抛异常不整体失败、不丢条
///   （占位 AggregatedAppInfo：isFromCache=true、error 非空；channel 语义保持现状）
/// - 成功/失败/缓存计数与最终列表一致
void main() {
  late AppAddedDatabase db;
  late FakeChannel githubChannel;

  setUpAll(() {
    // Linux 系统仅有 libsqlite3.so.0（无 .so 符号链接），显式指定动态库
    open.overrideFor(OperatingSystem.linux,
        () => DynamicLibrary.open('libsqlite3.so.0'));
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});

    // 注意：sqflite_common_ffi 对 ':memory:' 按路径复用同一实例，
    // 必须清空残留数据保证用例隔离
    db = await AppAddedDatabase.create(dbPath: inMemoryDatabasePath);
    await db.addedAppDao.clearAll();
    final manager = AppAggregatorManager.instance;
    manager.debugDatabase = db;
    manager.debugChannelManager = ChannelManager.instance;

    githubChannel = FakeChannel(
      ChannelType.github,
      throwingAppId: 'app-2',
    );
    ChannelManager.instance.registerChannel(githubChannel);
  });

  tearDown(() async {
    await db.close();
  });

  test('16 条 addedApp：分片并行取详情，顺序保持、异常兜底、计数一致', () async {
    const total = 16;
    final manager = AppAggregatorManager.instance;

    // 注入 16 条 addedApp（addTime 递减 → getAllAddedApps 按 addTime DESC 返回 app-0..app-15）
    final base = DateTime.now().millisecondsSinceEpoch;
    for (var i = 0; i < total; i++) {
      await db.addedAppDao.insertApp(AddedAppInfo(
        channelId: 'github',
        appId: 'app-$i',
        addTime: base - i,
      ));
    }

    final result = await manager.getAggregatedApps();

    // 1. 不丢条：16 条全部返回（第 3 条为占位）
    expect(result, hasLength(total));

    // 2. 结构性并行证据：最大并发 in-flight >= 2（串行实现恒为 1）
    expect(
      githubChannel.maxConcurrent,
      greaterThanOrEqualTo(2),
      reason: '分片 Future.wait 应产生并发：max in-flight=${githubChannel.maxConcurrent}',
    );

    // 3. 顺序与输入一致（addTime 倒序 = app-0..app-15）
    for (var i = 0; i < total; i++) {
      expect(result[i].addedAppInfo.appId, 'app-$i',
          reason: '位置 $i 应为 app-$i（顺序保持）');
    }

    // 4. 第 3 条（app-2）为异常兜底占位：isFromCache=true、error 非空
    final fallback = result[2];
    expect(fallback.isFromCache, isTrue);
    expect(fallback.error, isNotNull);
    expect(fallback.addedAppInfo.appId, 'app-2');

    // 5. 其余 15 条正常：非缓存、无错误
    for (var i = 0; i < total; i++) {
      if (i == 2) continue;
      expect(result[i].isFromCache, isFalse,
          reason: 'app-$i 应成功获取，非缓存占位');
      expect(result[i].error, isNull);
    }

    // 6. 计数一致：成功 15 / 异常兜底占位（isFromCache=true、error 非空）1
    //    注意：异常兜底占位同样置 isFromCache=true，故 cached 计数实际统计的是占位条数而非缓存命中数
    final failed = result.where((e) => e.error != null).length;
    final cached = result.where((e) => e.isFromCache).length;
    final ok = result.where((e) => e.error == null && !e.isFromCache).length;
    expect(failed, 1);
    expect(cached, 1);
    expect(ok, total - 1);
  });
}
