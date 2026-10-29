import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:gstore/core/aggregate/added_app_types.dart';
import 'package:gstore/core/catalog/catalog_facade.dart';
import 'package:gstore/core/channel/ChannelManager.dart';
import 'package:gstore/core/channel/channel.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/event/database_event.dart';
import 'package:gstore/core/model/AppIdentity.dart';
import 'package:gstore/core/model/AppSummary.dart';
import 'package:gstore/core/script/rust_script_lane.dart';

/// 应用聚合管理器
///
/// DB-free：持久化在 Rust core，本类只保留纯 join 工具（[aggregateWithMeta]）
/// 与变化通知。S3 起首页读模型由 Rust `LibraryApi.page` 提供，本类不再参与
/// 首页读取；[aggregateWithMeta] 仅供遗留/测试路径使用。
///
/// 变化通知：[appsChangedStream] 退化为纯信号（payload 恒为空列表），消费方
/// 收到信号后经 `AddedAppsFacade` 重新读取核心投影。
class AppAggregatorManager {
  static AppAggregatorManager? _instance;
  static AppAggregatorManager get instance {
    _instance ??= AppAggregatorManager._internal();
    return _instance!;
  }

  AppAggregatorManager._internal();

  late ChannelManager _channelManager;

  /// 测试注入：指定渠道管理器（未注册渠道时 getChannel 返回 null，跳过渠道库同步）
  @visibleForTesting
  set debugChannelManager(ChannelManager manager) => _channelManager = manager;

  /// 流控制器 - 已添加应用变化通知（DB-free 后为纯信号，payload 恒为空）
  final _appsChangedController = StreamController<List<AddedAppInfo>>.broadcast();

  /// 已添加应用变化流
  Stream<List<AddedAppInfo>> get appsChangedStream => _appsChangedController.stream;

  /// 是否已初始化
  bool _isInitialized = false;

  /// 数据库事件订阅（initialize 建立，可取消）
  StreamSubscription<DatabaseChangeEvent>? _eventSub;

  /// 初始化
  Future<void> initialize() async {
    if (_isInitialized) return;

    try {
      _channelManager = ChannelManager.instance;
      _isInitialized = true;

      // 监听数据库变化事件
      try {
        final eventBus = DatabaseEventBus.instance;
        _eventSub = eventBus.eventStream.listen((event) {
          appLog.info('AppAggregatorManager: ✅ 收到数据库事件 - ${event.type}');
          debugPrint('AppAggregatorManager: 开始刷新应用列表...');
          // 任何数据库变化都触发应用列表刷新
          _notifyAppsChanged();
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

  /// 通知聚合层应用数据变化（渠道记录被外部更新后调用，触发首页刷新）
  void notifyAppsChanged() => _notifyAppsChanged();

  /// 加载 localdb 渠道分类 ID → 中文 description 映射
  ///
  /// localdb 数据仓库的 AppInfo.category 存英文 ID（如 'PROXY'），而发现页
  /// 用户标签存中文 description（如 '代理'）。聚合时用此映射把英文 ID 归一化
  /// 为中文，避免首页出现 'PROXY' / '代理' 并存。
  /// 查询失败/异常一律返回空映射（降级为原样合并），绝不影响聚合流程。
  ///
  /// 分类由 Rust core 拥有（`CatalogFacade.categories()`）；旧 `LocalDbChannel`
  /// 已删除，不能再经渠道管理器读取（否则恒返回空映射，静默关闭归一化）。
  Future<Map<String, String>> _loadCategoryIdToDescription() async {
    try {
      final categories = await CatalogFacade.instance.categories();

      final map = <String, String>{};
      for (final category in categories) {
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

  /// 读取分类映射，并对给定切片执行分片并行渠道详情聚合。
  ///
  /// **纯合并**：行与标签索引由调用方提供（`addedApps` + `tagsIndex`），本方法
  /// 不读聚合库、也不回调 `AddedAppsFacade`，只做渠道详情分片查询与分类归一化。
  /// 因此 `AddedAppsFacade` 可以按 flag 从核心/旧 backend 取行与标签后委托此
  /// 方法——任意 flag 取值都不会递归。
  Future<List<AggregatedAppInfo>> aggregateWithMeta(
    List<AddedAppInfo> addedApps, {
    required Map<String, List<String>> tagsIndex,
  }) async {
    const sliceSize = 8;
    debugPrint('AppAggregatorManager: 从聚合数据库获取到 ${addedApps.length} 个应用');

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
        // Rust 脚本通道（`js_<stem>`）刻意不注册为 Dart channel，
        // getChannelByCode 恒返回 null；若直接丢弃，入库成功的 JS 应用永远
        // 不出现在首页（"js渠道入库成功，但是首页不显示"）。flag on 且命中
        // 通道包时走 lane 分支取真实元数据。
        final lane = RustScriptChannelLane.instance;
        if (channel == null && lane.enabled && lane.packFor(channelCode) != null) {
          return _aggregateRustLaneApp(addedApp, mergeCategories);
        }
        // 其余未知渠道（既无 Dart 实例、又非门面可用的枚举 code）保持原有丢弃语义；
        // 门面可用的枚举渠道（github/vivo/fdroid）即使没有 Dart 实例也应聚合。
        if (channel == null && !_channelManager.facadeEligible(channelCode)) {
          debugPrint('AppAggregatorManager: 跳过未知渠道 - $channelCode');
          return null;
        }

        debugPrint('AppAggregatorManager: 正在获取应用详情 - ${addedApp.appId} ($channelCode)');
        // 经 ChannelManager 门面路由：flag on 时读 Rust core 的 channel_apps
        // （core 拥有 channel 域后 Dart 渠道库是切轨前冻结副本、其读辅助被
        // LegacyWriteGuard 拦截 → 图标/详情恒空），flag off 回落 Dart IChannel。
        final result =
            await _channelManager.getAppInfoByCode(channelCode, addedApp.appId);
        final key = '${addedApp.channelId}:${addedApp.appId}';
        final channelType =
            ChannelType.fromCode(channelCode) ?? ChannelType.custom;

        if (result.success && result.data != null) {
          final summary = result.data!;
          final merged = mergeCategories(summary, key);
          return AggregatedAppInfo(
            addedAppInfo: addedApp,
            appInfo: merged.isEmpty
                ? summary
                : summary.copyWith(category: merged),
            channel: channelType,
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
            channel: channelType,
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

  /// 聚合一个 Rust 脚本通道（`js_<stem>`）行。
  ///
  /// 通道包刻意不注册为 Dart channel，`getChannelByCode` 恒返回 null；此分支
  /// （flag on 且 [RustScriptChannelLane.packFor] 命中）从通道已保存行
  /// （[RustScriptChannelLane.storedApps]）按 appId 取真实元数据（name/icon/...），
  /// 匹配不到则回落到 appId 占位；分类合并与其他分支一致。
  ///
  /// `channel` 用 [ChannelType.custom]（枚举无脚本类型；badge 渲染为 'APP' +
  /// primary 品牌色，不改动枚举本身）。`isFromCache: false`：这是通道的真实数据，
  /// 不是缓存兜底。读取失败由调用方的 catch 兜底（应用仍会出现）。
  Future<AggregatedAppInfo> _aggregateRustLaneApp(
    AddedAppInfo addedApp,
    List<String> Function(AppSummary summary, String key) mergeCategories,
  ) async {
    final channelCode = addedApp.channelId;
    final key = '${addedApp.channelId}:${addedApp.appId}';
    final laneApps = await RustScriptChannelLane.instance.storedApps(channelCode);
    var summary = _createAppSummaryFromAdded(addedApp);
    for (final app in laneApps) {
      if (app.appId == addedApp.appId) {
        summary = app;
        break;
      }
    }
    final merged = mergeCategories(summary, key);
    return AggregatedAppInfo(
      addedAppInfo: addedApp,
      appInfo: merged.isEmpty ? summary : summary.copyWith(category: merged),
      channel: ChannelType.custom,
      channelCode: channelCode,
      isFromCache: false,
    );
  }

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

  /// 通知应用列表变化。
  ///
  /// DB-free 后没有本地行可广播：本流退化为纯信号（payload 恒为空列表），
  /// 消费方（首页/发现页）收到信号后经 `AddedAppsFacade` 重新读取核心投影。
  void _notifyAppsChanged() {
    debugPrint('AppAggregatorManager: _notifyAppsChanged() 被调用');
    _appsChangedController.add(const <AddedAppInfo>[]);
    debugPrint('AppAggregatorManager: 已发送 appsChangedStream 信号');
  }

  /// 释放资源
  Future<void> dispose() async {
    await _eventSub?.cancel();
    await _appsChangedController.close();
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

  /// 统一读模型给出的元数据来源：`resolved` / `from_channel_store` /
  /// `unresolved`（Dart 侧纯 join 路径为 null）。
  final String? metadataState;

  AggregatedAppInfo({
    required this.addedAppInfo,
    required this.appInfo,
    required this.channel,
    required this.channelCode,
    this.isFromCache = false,
    this.error,
    this.metadataState,
  });

  /// 应用身份（渠道 + 渠道内 ID + 真实包名）
  AppIdentity get identity => AppIdentity(
        channel: channel,
        channelAppId: addedAppInfo.appId,
        packageName: appInfo.packageName,
      );
}
