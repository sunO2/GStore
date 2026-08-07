import 'package:flutter/material.dart';
import 'package:gstore/core/channel/model/AppUpdateCheckResult.dart';
import 'package:gstore/core/channel/model/ChannelInfo.dart';
import 'package:gstore/core/channel/model/ChannelResult.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';
import 'package:gstore/core/model/IDetailInfo.dart';
import 'package:gstore/db/apps/AppInfo.dart';
import 'package:gstore/db/apps/AppInfo.dart' as db;

/// 渠道抽象接口
/// 定义所有渠道必须实现的基本操作
abstract interface class IChannel {
  /// 获取渠道信息
  ChannelInfo get info;

  /// 初始化渠道
  Future<void> initialize();

  /// 是否已初始化
  bool get isInitialized;

  /// 检查渠道是否可用
  Future<bool> checkAvailable();

  /// 获取添加应用的 Widget（用于 Bottom Sheet）
  /// 返回 null 表示不支持添加功能
  /// onAppAdded: 添加到聚合管理器的回调
  /// onAppSaved: 保存到渠道数据库后的回调（用于刷新列表）
  Widget? getAddAppWidget(
    BuildContext context,
    Function(AppInfo) onAppAdded, {
    VoidCallback? onAppSaved,
  });

  // ==================== 应用信息查询 ====================

  /// 获取所有应用
  Future<ChannelResult<List<AppInfo>>> getAllApps({
    bool forceRefresh = false,
  });

  /// 根据 appId 获取应用信息
  Future<ChannelResult<AppInfo?>> getAppInfo(
    String appId, {
    bool forceRefresh = false,
  });

  /// 获取应用详情（用于详情页面展示）
  /// 返回 IDetailInfo 接口，由各渠道实现具体数据
  Future<ChannelResult<IDetailInfo>> getAppDetail(
    String appId, {
    bool forceRefresh = false,
  });

  /// 检查指定应用是否有新版本（更新检测统一入口）
  /// 由各渠道内部决定数据源（本地索引 / releases / 数据库 / 网络 API 等）
  Future<ChannelResult<AppUpdateCheckResult>> checkAppUpdate(String appId);

  /// 保存搜索结果到渠道数据库（添加应用到渠道）
  /// 各渠道实现；不支持的渠道返回 failure
  Future<ChannelResult<void>> addApp(AppInfo app);

  /// 从渠道数据库移除应用
  Future<ChannelResult<void>> removeApp(String appId);

  /// 搜索应用（支持按名称和描述搜索）
  Future<ChannelResult<List<AppInfo>>> searchApps(
    String keyword, {
    bool forceRefresh = false,
  });

  /// 按分类搜索应用
  Future<ChannelResult<List<AppInfo>>> searchByCategory(
    String categoryId, {
    bool forceRefresh = false,
  });

  // ==================== 分类信息查询 ====================

  /// 获取所有分类
  Future<ChannelResult<List<db.AppCategory>>> getAllCategories({
    bool forceRefresh = false,
  });

  // ==================== 更新与配置 ====================

  /// 检查数据更新
  /// 返回是否有新版本可用
  Future<ChannelResult<bool>> checkUpdate();

  /// 执行数据更新
  /// onProgress: 进度回调 (当前, 总数)
  Future<ChannelResult<bool>> doUpdate({
    Function(int current, int total)? onProgress,
  });

  /// 获取配置信息
  Future<ChannelResult<db.AppInfoConfig?>> getConfig({
    bool forceRefresh = false,
  });

  // ==================== 缓存管理 ====================

  /// 清除缓存
  Future<void> clearCache();

  /// 获取缓存大小（字节）
  Future<int> getCacheSize();

  // ==================== 生命周期 ====================

  /// 释放资源
  Future<void> dispose();
}
