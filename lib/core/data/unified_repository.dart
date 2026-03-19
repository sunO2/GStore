/// 统一应用仓库实现
/// 实现 IAppRepository 接口
library;

import 'package:flutter/foundation.dart';
import 'package:gstore/core/model/IAppInfo.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';
import 'package:gstore/core/model/IDetailInfo.dart';
import 'package:gstore/core/model/AppInfoEntity.dart';
import 'package:gstore/core/model/AppRepository.dart';
import 'package:gstore/core/data/unified_database.dart';
import 'package:gstore/core/channel/ChannelManager.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/model/proxy/ChannelDetailProxy.dart';

/// 统一应用仓库实现
class UnifiedAppRepository implements IAppRepository {
  late UnifiedDatabase _database;
  late ChannelManager _channelManager;

  /// 初始化仓库
  Future<void> initialize() async {
    _database = UnifiedDatabase();
    _channelManager = ChannelManager.instance;
    debugPrint('UnifiedAppRepository: 初始化成功');
  }

  @override
  Future<RepositoryResult<List<IAppInfo>>> getAllApps() async {
    try {
      final entities = await _database.getAllApps();
      final apps = entities.map((e) => _entityToInterface(e)).toList();
      return RepositoryResult.success(apps);
    } catch (e) {
      debugPrint('UnifiedAppRepository: 获取应用列表失败 - $e');
      return RepositoryResult.failure(e.toString());
    }
  }

  @override
  Future<RepositoryResult<IAppInfo?>> getAppByPackage(String packageName) async {
    try {
      final entity = await _database.findByPackage(packageName);
      if (entity == null) {
        return RepositoryResult.success(null);
      }
      return RepositoryResult.success(_entityToInterface(entity));
    } catch (e) {
      debugPrint('UnifiedAppRepository: 获取应用失败 - $e');
      return RepositoryResult.failure(e.toString());
    }
  }

  @override
  Future<RepositoryResult<IDetailInfo?>> getAppDetail(String packageName) async {
    try {
      // 先从数据库获取基础信息
      final entity = await _database.findByPackage(packageName);
      if (entity == null) {
        return RepositoryResult.failure('应用不存在');
      }

      // 根据渠道ID获取详情
      final channelId = entity.channelId;
      final channelType = ChannelType.fromCode(channelId);
      if (channelType == null) {
        return RepositoryResult.failure('无效的渠道ID: $channelId');
      }
      final channel = _channelManager.getChannel(channelType);

      if (channel == null) {
        return RepositoryResult.failure('渠道不存在: $channelId');
      }

      // 从渠道获取详情（使用 packageName）
      final result = await channel.getAppDetail(packageName, forceRefresh: false);

      if (!result.success || result.data == null) {
        return RepositoryResult.failure(result.error ?? '获取详情失败');
      }

      return RepositoryResult.success(result.data);
    } catch (e) {
      debugPrint('UnifiedAppRepository: 获取详情失败 - $e');
      return RepositoryResult.failure(e.toString());
    }
  }

  @override
  Future<RepositoryResult<void>> addApp(IAppInfo app) async {
    try {
      // 需要知道渠道ID，从extra或其他地方获取
      // 这里简化处理，假设app包含渠道信息
      String channelId = 'unknown';
      if (app is Map && (app as Map).containsKey('channelId')) {
        channelId = (app as Map)['channelId'].toString();
      }

      final entity = AppInfoEntity(
        packageName: app.packageName,
        appName: app.appName,
        icon: app.icon,
        description: app.description,
        channelId: channelId,
      );

      await _database.insertApp(entity);
      return RepositoryResult.success(null);
    } catch (e) {
      debugPrint('UnifiedAppRepository: 添加应用失败 - $e');
      return RepositoryResult.failure(e.toString());
    }
  }

  @override
  Future<RepositoryResult<void>> updateApp(IAppInfo app) async {
    try {
      // TODO: 实现更新逻辑
      return RepositoryResult.failure('未实现');
    } catch (e) {
      return RepositoryResult.failure(e.toString());
    }
  }

  @override
  Future<RepositoryResult<void>> deleteApp(String packageName) async {
    try {
      await _database.deleteByPackage(packageName);
      return RepositoryResult.success(null);
    } catch (e) {
      debugPrint('UnifiedAppRepository: 删除应用失败 - $e');
      return RepositoryResult.failure(e.toString());
    }
  }

  @override
  Future<RepositoryResult<List<IAppInfo>>> getAppsByChannel(String channelId) async {
    try {
      final entities = await _database.getAppsByChannel(channelId);
      final apps = entities.map((e) => _entityToInterface(e)).toList();
      return RepositoryResult.success(apps);
    } catch (e) {
      debugPrint('UnifiedAppRepository: 获取渠道应用失败 - $e');
      return RepositoryResult.failure(e.toString());
    }
  }

  @override
  Future<RepositoryResult<List<IAppInfo>>> searchApps(String keyword) async {
    try {
      final entities = await _database.searchApps(keyword);
      final apps = entities.map((e) => _entityToInterface(e)).toList();
      return RepositoryResult.success(apps);
    } catch (e) {
      debugPrint('UnifiedAppRepository: 搜索应用失败 - $e');
      return RepositoryResult.failure(e.toString());
    }
  }

  @override
  Future<RepositoryResult<void>> addApps(List<IAppInfo> apps) async {
    try {
      final entities = apps.map((app) => AppInfoEntity(
        packageName: app.packageName,
        appName: app.appName,
        icon: app.icon,
        description: app.description,
        channelId: 'unknown', // TODO: 需要从app中提取
      )).toList();

      await _database.insertApps(entities);
      return RepositoryResult.success(null);
    } catch (e) {
      debugPrint('UnifiedAppRepository: 批量添加应用失败 - $e');
      return RepositoryResult.failure(e.toString());
    }
  }

  @override
  Future<RepositoryResult<void>> clearAll() async {
    try {
      await _database.deleteAll();
      return RepositoryResult.success(null);
    } catch (e) {
      debugPrint('UnifiedAppRepository: 清空应用失败 - $e');
      return RepositoryResult.failure(e.toString());
    }
  }

  @override
  Future<int> getCount() async {
    return await _database.getCount();
  }

  @override
  Future<bool> exists(String packageName) async {
    return await _database.exists(packageName);
  }

  /// 将 AppInfoEntity 转换为 IAppInfo 接口
  IAppInfo _entityToInterface(AppInfoEntity entity) {
    return _AppInfoImpl(
      packageName: entity.packageName,
      appName: entity.appName,
      icon: entity.icon,
      description: entity.description,
    );
  }
}

/// IAppInfo 的简单实现类
/// 用于内部数据转换
class _AppInfoImpl implements IAppInfo {
  @override
  final String packageName;

  @override
  final String appName;

  @override
  final String icon;

  @override
  final String description;

  _AppInfoImpl({
    required this.packageName,
    required this.appName,
    required this.icon,
    required this.description,
  });
}
