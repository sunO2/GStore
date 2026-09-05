import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:get/get.dart';
import 'package:gstore/core/aggregate/AppAddedDatabase.dart';
import 'package:gstore/core/channel/ChannelManager.dart';
import 'package:gstore/core/channel/channel.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/event/database_event.dart';
import 'package:gstore/core/module/interfaces/service_interfaces.dart';
import 'package:gstore/core/model/AppIdentity.dart';
import 'package:gstore/core/model/AppSummary.dart';

/// 应用聚合管理器
/// 负责管理所有渠道已添加的应用
class AppAggregatorManager implements IAggregateService {
  static AppAggregatorManager? _instance;
  static AppAggregatorManager get instance {
    _instance ??= AppAggregatorManager._internal();
    return _instance!;
  }

  AppAggregatorManager._internal();

  late AppAddedDatabase _database;
  late ChannelManager _channelManager;

  /// 测试注入：跳过 initialize 的数据库创建
  @visibleForTesting
  set debugDatabase(AppAddedDatabase db) => _database = db;

  /// 测试注入：指定渠道管理器（未注册渠道时 getChannel 返回 null，跳过渠道库同步）
  @visibleForTesting
  set debugChannelManager(ChannelManager manager) => _channelManager = manager;

  /// 流控制器 - 已添加应用变化通知
  final _appsChangedController = StreamController<List<AddedAppInfo>>.broadcast();

  /// 已添加应用变化流
  @override
  Stream<List<AddedAppInfo>> get appsChangedStream => _appsChangedController.stream;

  /// 是否已初始化
  bool _isInitialized = false;

  /// 初始化
  Future<void> initialize() async {
    if (_isInitialized) return;

    try {
      _channelManager = ChannelManager.instance;

      // 初始化数据库
      final database = await AppAddedDatabase.create();

      _database = database;
      _isInitialized = true;

      // 监听数据库变化事件
      try {
        final eventBus = DatabaseEventBus.instance;
        ever(eventBus.eventStream, (event) {
          if (event != null) {
            appLog.info('AppAggregatorManager: ✅ 收到数据库事件 - ${event.type}');
            debugPrint('AppAggregatorManager: 开始刷新应用列表...');
            // 任何数据库变化都触发应用列表刷新
            _notifyAppsChanged();
          }
        });
        appLog.info('AppAggregatorManager: 数据库事件监听已注册');
      } catch (e) {
        appLog.error('AppAggregatorManager: 注册数据库事件监听失败 - $e');
      }

      appLog.info('AppAggregatorManager: 初始化成功');
    } catch (e) {
      appLog.error('AppAggregatorManager: 初始化失败 - $e');
      rethrow;
    }
  }

  // ==================== 添加/移除应用 ====================

  /// 添加应用
  ///
  /// 聚合库只存引用（渠道 + 应用 ID + 聚合元数据），应用信息由渠道实时查询。
  /// - appId 形态由渠道自报（IChannel.canonicalAppId，外部无感）：
  ///   GitHub metadata 已收录 → 真实包名；未收录 → owner/repo 占位
  /// - 统一调用渠道 addApp 落渠道库（渠道自行决定是否支持/如何保存），失败不阻断首页添加
  Future<void> addApp({
    required String channelCode,
    required AppSummary appInfo,
    int? sortOrder,
  }) async {
    // 渠道自报规范化 appId（无感调用）
    final channelInstance = _channelManager.getChannelByCode(channelCode);
    final appId = channelInstance != null
        ? await channelInstance.canonicalAppId(appInfo)
        : appInfo.appId;

    final now = DateTime.now().millisecondsSinceEpoch;
    // 幂等：已存在（channelId + appId）时更新而非新增（自增 id 主键无唯一约束）
    final existing = await _database.addedAppDao.getApp(channelCode, appId);
    if (existing != null) {
      await _database.addedAppDao.updateApp(AddedAppInfo(
        id: existing.id,
        channelId: channelCode,
        appId: appId,
        addTime: now,
        sortOrder: sortOrder ?? existing.sortOrder,
        isEnabled: existing.isEnabled,
      ));
    } else {
      await _database.addedAppDao.insertApp(AddedAppInfo(
        channelId: channelCode,
        appId: appId,
        addTime: now,
        sortOrder: sortOrder ?? 0,
      ));
    }

    // 统一添加入口：渠道自己落渠道库（GitHub 收录/未收录、Vivo、Fdroid 等由渠道决定）
    // 失败不阻断首页添加（LocalDb/Http 等不支持 addApp 的渠道忽略）
    if (channelInstance != null) {
      try {
        final enhanced = appId != appInfo.appId
            ? AppSummary(
                appId: appId,
                packageName: null,
                name: appInfo.name,
                user: appInfo.user,
                repositories: appInfo.repositories,
                icon: appInfo.icon,
                des: appInfo.des,
                category: appInfo.category,
              )
            : appInfo;
        await channelInstance.addApp(enhanced);
      } catch (e) {
        appLog.error('AppAggregatorManager: 渠道保存失败（不影响首页添加）- $e');
      }
    }

    // 通知变化
    _notifyAppsChanged();

    appLog.info('AppAggregatorManager: 添加应用 - $appId ($channelCode)');
  }

  /// 批量添加应用
  @override
  Future<void> addApps({
    required String channelCode,
    required List<AppSummary> appInfos,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final channelInstance = _channelManager.getChannelByCode(channelCode);
    final addedApps = <AddedAppInfo>[];

    for (final app in appInfos) {
      final appId = channelInstance != null
          ? await channelInstance.canonicalAppId(app)
          : app.appId;

      // 幂等：已存在则更新，否则新增
      final existing = await _database.addedAppDao.getApp(channelCode, appId);
      if (existing != null) {
        await _database.addedAppDao.updateApp(AddedAppInfo(
          id: existing.id,
          channelId: channelCode,
          appId: appId,
          addTime: now,
          sortOrder: existing.sortOrder,
          isEnabled: existing.isEnabled,
        ));
      } else {
        addedApps.add(AddedAppInfo(
          channelId: channelCode,
          appId: appId,
          addTime: now,
        ));
      }

      // 统一添加入口：渠道自己落渠道库（失败不阻断）
      if (channelInstance != null) {
        try {
          final enhanced = appId != app.appId
              ? AppSummary(
                  appId: appId,
                  packageName: null,
                  name: app.name,
                  user: app.user,
                  repositories: app.repositories,
                  icon: app.icon,
                  des: app.des,
                  category: app.category,
                )
              : app;
          await channelInstance.addApp(enhanced);
        } catch (e) {
          appLog.error('AppAggregatorManager: 渠道保存失败（不影响首页添加）- $e');
        }
      }
    }

    if (addedApps.isNotEmpty) {
      await _database.addedAppDao.insertApps(addedApps);
    }

    _notifyAppsChanged();

    appLog.info('AppAggregatorManager: 批量添加 ${appInfos.length} 个应用 ($channelCode)');
  }

  /// 移除应用
  Future<void> removeApp({
    required String channelCode,
    required String appId,
  }) async {
    await _database.addedAppDao.removeApp(channelCode, appId);
    // 联动清理该应用的用户标签（避免残留孤儿标签）
    try {
      await _database.appTagDao.removeTagsOfApp(channelCode, appId);
    } catch (e) {
      appLog.error('AppAggregatorManager: 清理标签失败 - $e');
    }

    _notifyAppsChanged();

    appLog.info('AppAggregatorManager: 移除应用 - $appId ($channelCode)');
  }

  /// 聚合库应用 ID 改名（渠道记录 appId 迁移后调用，保持聚合库 appId 与渠道一致）
  ///
  /// 只操作聚合库（added_apps + 用户标签），不触碰渠道库——渠道库由渠道/服务自行迁移。
  /// - 保留 id/addTime/sortOrder/isEnabled（updateApp 按 id 更新，避免 remove+insert 重置元数据）
  /// - 目标 appId 已存在（异常残留）时合并：删源行、标签并入目标行
  /// - 幂等：源记录不存在时 no-op
  Future<void> renameApp({
    required String channelCode,
    required String oldAppId,
    required String newAppId,
  }) async {
    if (oldAppId == newAppId) return;
    final db = _database;

    final existing = await db.addedAppDao.getApp(channelCode, oldAppId);
    if (existing == null) return; // 幂等：源不存在直接返回

    // 目标 appId 已存在（异常残留）→ 删源行，保留目标行元数据
    final target = await db.addedAppDao.getApp(channelCode, newAppId);
    if (target != null) {
      await db.addedAppDao.removeApp(channelCode, oldAppId);
    } else {
      // 常规改名：updateApp 保留原 id（addTime/sortOrder/isEnabled 不变）
      await db.addedAppDao.updateApp(AddedAppInfo(
        id: existing.id,
        channelId: channelCode,
        appId: newAppId,
        addTime: existing.addTime,
        sortOrder: existing.sortOrder,
        isEnabled: existing.isEnabled,
      ));
    }

    // 标签迁移（旧 appId → 新 appId，避免孤儿标签/丢失）
    final tags = await db.appTagDao.getTags(channelCode, oldAppId);
    if (tags.isNotEmpty) {
      await db.appTagDao.removeTagsOfApp(channelCode, oldAppId);
      await db.appTagDao.insertTags([
        for (final t in tags)
          AddedAppTag(channelId: channelCode, appId: newAppId, tag: t.tag),
      ]);
    }

    _notifyAppsChanged();
    appLog.info('AppAggregatorManager: 应用 ID 改名 $oldAppId -> $newAppId ($channelCode)');
  }

  /// 通知聚合层应用数据变化（渠道记录被外部更新后调用，触发首页刷新）
  void notifyAppsChanged() => _notifyAppsChanged();

  // ==================== 用户标签 ====================

  /// 获取应用的用户标签（无标签返回空列表）
  @override
  Future<List<String>> getTags({
    required String channelCode,
    required String appId,
  }) async {
    try {
      final rows =
          await _database.appTagDao.getTags(channelCode, appId);
      return rows.map((e) => e.tag).toList();
    } catch (e) {
      appLog.error('AppAggregatorManager: 获取标签失败 - $e');
      return [];
    }
  }

  /// 设置应用的用户标签（整体替换：先清空再写入）
  @override
  Future<void> setTags({
    required String channelCode,
    required String appId,
    required List<String> tags,
  }) async {
    try {
      await _database.appTagDao.removeTagsOfApp(channelCode, appId);
      final deduped = tags.toSet().where((t) => t.trim().isNotEmpty).toList();
      if (deduped.isNotEmpty) {
        await _database.appTagDao.insertTags([
          for (final t in deduped)
            AddedAppTag(channelId: channelCode, appId: appId, tag: t.trim()),
        ]);
      }
      // 标签变化 → 通知首页刷新（getAggregatedApps 会合并新标签到分类）
      _notifyAppsChanged();
    } catch (e) {
      appLog.error('AppAggregatorManager: 设置标签失败 - $e');
      rethrow;
    }
  }

  /// 为应用添加单个标签（幂等，已有则跳过）
  Future<void> addTag({
    required String channelCode,
    required String appId,
    required String tag,
  }) async {
    final t = tag.trim();
    if (t.isEmpty) return;
    try {
      await _database.appTagDao.insertTag(
        AddedAppTag(channelId: channelCode, appId: appId, tag: t),
      );
    } catch (e) {
      appLog.error('AppAggregatorManager: 添加标签失败 - $e');
    }
  }

  /// 移除应用单个标签
  Future<void> removeTag({
    required String channelCode,
    required String appId,
    required String tag,
  }) async {
    try {
      await _database.appTagDao.removeTag(channelCode, appId, tag);
    } catch (e) {
      appLog.error('AppAggregatorManager: 移除标签失败 - $e');
    }
  }

  /// 获取全部标签索引：Map<"channelId:appId", List<String>>
  /// 供 getAggregatedApps 一次性合并，避免逐应用查询
  Future<Map<String, List<String>>> getAllTagsIndex() async {
    try {
      final all = await _database.appTagDao.getAllTags();
      final index = <String, List<String>>{};
      for (final row in all) {
        final key = '${row.channelId}:${row.appId}';
        index.putIfAbsent(key, () => []).add(row.tag);
      }
      return index;
    } catch (e) {
      appLog.error('AppAggregatorManager: 获取标签索引失败 - $e');
      return {};
    }
  }

  /// 加载 localdb 渠道分类 ID → 中文 description 映射
  ///
  /// localdb 数据仓库的 AppInfo.category 存英文 ID（如 'PROXY'），而发现页
  /// 用户标签存中文 description（如 '代理'）。聚合时用此映射把英文 ID 归一化
  /// 为中文，避免首页出现 'PROXY' / '代理' 并存。
  /// 渠道缺失/查询失败/异常一律返回空映射（降级为原样合并），绝不影响聚合流程。
  Future<Map<String, String>> _loadCategoryIdToDescription() async {
    try {
      final channel = _channelManager.getChannelByCode(ChannelType.localDb.code);
      if (channel == null) return {};

      final result = await channel.getAllCategories();
      if (!result.success || result.data == null) return {};

      final map = <String, String>{};
      for (final category in result.data!) {
        final id = category.id.trim();
        final description = category.description.trim();
        if (id.isEmpty || description.isEmpty) continue;
        map[id] = description;
      }
      return map;
    } catch (e) {
      appLog.error('AppAggregatorManager: 加载分类 ID → description 映射失败 - $e');
      return {};
    }
  }

  /// 切换应用添加状态
  @override
  Future<bool> toggleApp({
    required String channelCode,
    required AppSummary appInfo,
  }) async {
    final isAdded = await isAppAdded(channelCode: channelCode, appId: appInfo.appId);

    if (isAdded) {
      await removeApp(channelCode: channelCode, appId: appInfo.appId);
      return false;
    } else {
      await addApp(channelCode: channelCode, appInfo: appInfo);
      return true;
    }
  }

  /// 清空指定渠道的所有应用
  @override
  Future<void> clearChannel(String channelCode) async {
    await _database.addedAppDao.clearChannel(channelCode);

    _notifyAppsChanged();

    appLog.info('AppAggregatorManager: 清空渠道 - $channelCode');
  }

  /// 清空所有应用
  Future<void> clearAll() async {
    await _database.addedAppDao.clearAll();

    _notifyAppsChanged();

    appLog.info('AppAggregatorManager: 清空所有应用');
  }

  // ==================== 查询方法 ====================

  /// 获取所有已添加的应用（按添加时间倒序）
  Future<List<AddedAppInfo>> getAllAddedApps() async {
    return await _database.addedAppDao.getAllAddedApps();
  }

  /// 获取指定渠道的已添加应用
  Future<List<AddedAppInfo>> getAppsByChannel(String channelCode) async {
    return await _database.addedAppDao.getAppsByChannel(channelCode);
  }

  /// 检查应用是否已添加
  Future<bool> isAppAdded({
    required String channelCode,
    required String appId,
  }) async {
    final app = await _database.addedAppDao.getApp(channelCode, appId);
    return app != null;
  }

  /// 获取应用总数
  Future<int> getTotalCount() async {
    return await _database.addedAppDao.getTotalCount() ?? 0;
  }

  /// 获取指定渠道的应用数量
  Future<int> getCountByChannel(String channelCode) async {
    return await _database.addedAppDao.getCountByChannel(channelCode) ?? 0;
  }

  /// 获取已添加应用的索引
  /// 返回 Map<ChannelCode, Set<AppId>>
  @override
  Future<Map<String, Set<String>>> getAddedAppsIndex() async {
    final allApps = await getAllAddedApps();

    final index = <String, Set<String>>{};

    for (var app in allApps) {
      index.putIfAbsent(app.channelId, () => {});
      index[app.channelId]!.add(app.appId);
    }

    return index;
  }

  /// 从渠道获取已添加应用的详细信息
  /// 聚合所有渠道的已添加应用
  /// 分片并行：每片 8 个 addedApp 用 Future.wait 并发查询；
  /// 结果按输入索引回填、跳过 null（未知渠道/渠道实例为空，等价原串行 continue）并压缩顺序，
  /// 最终列表顺序与 addedApps（addTime 倒序）一致
  ///
  /// 全量聚合：一次性取所有已添加应用的渠道详情（分页场景请用 [getAggregatedAppsPage]，
  /// 避免应用数量大时首屏阻塞）。内部与分页版共享分片逻辑。
  @override
  Future<List<AggregatedAppInfo>> getAggregatedApps() async {
    final addedApps = await getAllAddedApps();
    return _aggregateWithMeta(addedApps);
  }

  /// 分页获取聚合应用详情
  ///
  /// 仅对 addedApps 中 [offset, offset+limit) 的应用发起渠道详情查询（保持 8 并发的
  /// 分片逻辑），返回 (本页聚合应用, 已添加应用总数)。首屏只取第一页 → 快速渲染；
  /// 滚动到底部再取下一页 → 避免一次性加载太多应用导致网络读取耗时。
  @override
  Future<(List<AggregatedAppInfo> apps, int total)> getAggregatedAppsPage({
    required int offset,
    required int limit,
  }) async {
    final addedApps = await getAllAddedApps();
    final total = addedApps.length;
    if (offset >= total || limit <= 0) {
      return (<AggregatedAppInfo>[], total);
    }

    final end = (offset + limit > total) ? total : offset + limit;
    final apps = await _aggregateWithMeta(addedApps.sublist(offset, end));
    return (apps, total);
  }

  /// 读取标签索引 + 分类映射，并对给定切片执行分片并行渠道详情聚合
  Future<List<AggregatedAppInfo>> _aggregateWithMeta(
    List<AddedAppInfo> addedApps,
  ) async {
    const sliceSize = 8;
    debugPrint('AppAggregatorManager: 从聚合数据库获取到 ${addedApps.length} 个应用');

    // 一次性读取全部用户标签索引（channelId:appId → tags），供合并展示
    final tagsIndex = await getAllTagsIndex();

    // 一次性读取 localdb 渠道分类映射（英文 ID → 中文 description）；
    // 失败/缺失时为空映射，mergeCategories 降级为原样合并
    final categoryIdToDesc = await _loadCategoryIdToDescription();

    /// 合并渠道自带分类与用户标签（去重），并将 localdb 英文分类 ID
    /// 归一化为中文 description（映射表外自定义标签保留原文，跳过空值）
    List<String> mergeCategories(AppSummary summary, String key) {
      final merged = <String>{};
      for (final raw in [...?summary.category, ...?tagsIndex[key]]) {
        final value = raw.trim();
        if (value.isEmpty) continue;
        merged.add(categoryIdToDesc[value] ?? value);
      }
      return merged.toList();
    }

    // 分片并行：每片 sliceSize 个，片内 Future.wait 并发取详情，片间串行等待
    final results = <AggregatedAppInfo?>[];
    for (var start = 0; start < addedApps.length; start += sliceSize) {
      final end = (start + sliceSize > addedApps.length)
          ? addedApps.length
          : start + sliceSize;
      final slice = addedApps.sublist(start, end);
      results.addAll(await _aggregateSlice(slice, mergeCategories));
    }

    // 按输入索引回填：跳过 null（未知渠道/渠道实例为空的 continue 语义），压缩顺序
    final aggregatedApps = <AggregatedAppInfo>[
      for (final result in results)
        if (result != null) result,
    ];

    // 从最终结果统计（与逐片计数语义一致）：成功 = 非缓存；缓存兜底 = isFromCache 且无错误；
    // 失败 = 渠道异常兜底（error 非空）；未知渠道（null 被压缩）计入失败
    final failed = aggregatedApps.where((e) => e.error != null).length;
    final cache = aggregatedApps.where((e) => e.isFromCache && e.error == null).length;
    final success = aggregatedApps.where((e) => !e.isFromCache).length;
    appLog.info('AppAggregatorManager: 聚合完成 - 成功: $success, 缓存: $cache, 失败: $failed');
    return aggregatedApps;
  }

  /// 单分片聚合：片内 Future.wait 并发取详情，返回与输入等序的列表
  /// （成功/缓存兜底/异常兜底三种 AggregatedAppInfo；未知渠道返回 null 由调用方压缩）
  Future<List<AggregatedAppInfo?>> _aggregateSlice(
    List<AddedAppInfo> slice,
    List<String> Function(AppSummary summary, String key) mergeCategories,
  ) async {
    return Future.wait(slice.map((addedApp) async {
      final channelCode = addedApp.channelId;
      try {
        final channel = _channelManager.getChannelByCode(channelCode);
        if (channel == null) {
          debugPrint('AppAggregatorManager: 跳过未知渠道 - $channelCode');
          return null;
        }

        debugPrint('AppAggregatorManager: 正在获取应用详情 - ${addedApp.appId} ($channelCode)');
        final result = await channel.getAppInfo(addedApp.appId);
        final key = '${addedApp.channelId}:${addedApp.appId}';

        if (result.success && result.data != null) {
          final summary = result.data!;
          final merged = mergeCategories(summary, key);
          return AggregatedAppInfo(
            addedAppInfo: addedApp,
            appInfo: merged.isEmpty
                ? summary
                : summary.copyWith(category: merged),
            channel: channel.info.type,
            channelCode: channelCode,
          );
        } else {
          // 渠道获取失败，使用本地缓存的数据
          appLog.error('AppAggregatorManager: 渠道获取失败，使用缓存 - ${addedApp.appId}, error: ${result.error}');
          final summary = _createAppSummaryFromAdded(addedApp);
          final merged = mergeCategories(summary, key);
          return AggregatedAppInfo(
            addedAppInfo: addedApp,
            appInfo: merged.isEmpty
                ? summary
                : summary.copyWith(category: merged),
            channel: channel.info.type,
            channelCode: channelCode,
            isFromCache: true,
          );
        }
      } catch (e, stackTrace) {
        appLog.error('AppAggregatorManager: ❌ 获取应用详情异常');
        debugPrint('  - appId: ${addedApp.appId}');
        debugPrint('  - channelId: ${addedApp.channelId}');
        debugPrint('  - 异常类型: ${e.runtimeType}');
        debugPrint('  - 异常信息: $e');
        debugPrint('  - 堆栈跟踪: $stackTrace');
        // 使用本地缓存的数据
        final summary = _createAppSummaryFromAdded(addedApp);
        final key = '${addedApp.channelId}:${addedApp.appId}';
        final merged = mergeCategories(summary, key);
        return AggregatedAppInfo(
          addedAppInfo: addedApp,
          appInfo: merged.isEmpty
              ? summary
              : summary.copyWith(category: merged),
          channel: ChannelType.localDb,
          channelCode: channelCode,
          isFromCache: true,
          error: e.toString(),
        );
      }
    }));
  }

  // ==================== 私有方法 ====================

  /// 从 AddedAppInfo 创建占位 AppSummary（渠道查询失败时兜底）
  /// 聚合库只存引用，无应用信息副本；兜底显示 appId 与空图标（UI 占位）
  AppSummary _createAppSummaryFromAdded(AddedAppInfo addedApp) {
    return AppSummary(
      appId: addedApp.appId,
      packageName: null,
      name: addedApp.appId, // 占位名称（显示 appId）
      user: '', // user
      repositories: '', // repositories
      icon: '', // 空图标（UI 显示占位）
      des: '', // 描述
      category: null,
    );
  }

  /// 通知应用列表变化
  void _notifyAppsChanged() {
    debugPrint('AppAggregatorManager: _notifyAppsChanged() 被调用');
    getAllAddedApps().then((apps) {
      debugPrint('AppAggregatorManager: 获取到 ${apps.length} 个已添加应用，准备发送通知');
      _appsChangedController.add(apps);
      debugPrint('AppAggregatorManager: 已发送 appsChangedStream 事件');
    }).catchError((error) {
      appLog.error('AppAggregatorManager: 获取应用列表失败 - $error');
    });
  }

  /// 释放资源
  Future<void> dispose() async {
    await _appsChangedController.close();
    // 注意：不关闭数据库，可能被其他地方使用
  }
}

/// 聚合应用信息
class AggregatedAppInfo {
  /// 已添加应用信息
  final AddedAppInfo addedAppInfo;

  /// 应用详细信息
  final AppSummary appInfo;

  /// 来源渠道
  final ChannelType channel;

  /// 渠道唯一标识（枚举渠道 = type.code；脚本渠道 = channelKey）
  final String channelCode;

  /// 是否来自缓存
  final bool isFromCache;

  /// 错误信息
  final String? error;

  AggregatedAppInfo({
    required this.addedAppInfo,
    required this.appInfo,
    required this.channel,
    required this.channelCode,
    this.isFromCache = false,
    this.error,
  });

  /// 应用身份（渠道 + 渠道内 ID + 真实包名）
  AppIdentity get identity => AppIdentity(
        channel: channel,
        channelAppId: addedAppInfo.appId,
        packageName: appInfo.packageName,
      );
}
