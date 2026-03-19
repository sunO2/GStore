/// 应用数据仓库接口
/// 定义应用数据的CRUD操作
library;

import 'package:gstore/core/model/IAppInfo.dart';
import 'package:gstore/core/model/IDetailInfo.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';

/// 应用仓库操作结果
class RepositoryResult<T> {
  final T? data;
  final String? error;
  final bool success;

  RepositoryResult.success(this.data)
      : error = null,
        success = true;

  RepositoryResult.failure(this.error)
      : data = null,
        success = false;
}

/// 应用数据仓库接口
/// 定义应用数据的增删改查操作
abstract class IAppRepository {
  /// 获取所有应用
  Future<RepositoryResult<List<IAppInfo>>> getAllApps();

  /// 根据包名获取应用
  Future<RepositoryResult<IAppInfo?>> getAppByPackage(String packageName);

  /// 根据包名获取应用详情
  /// 从对应渠道获取完整详情信息
  Future<RepositoryResult<IDetailInfo?>> getAppDetail(String packageName);

  /// 添加应用
  Future<RepositoryResult<void>> addApp(IAppInfo app);

  /// 更新应用
  Future<RepositoryResult<void>> updateApp(IAppInfo app);

  /// 删除应用
  Future<RepositoryResult<void>> deleteApp(String packageName);

  /// 根据渠道获取应用列表
  Future<RepositoryResult<List<IAppInfo>>> getAppsByChannel(String channelId);

  /// 搜索应用
  /// 根据关键词搜索应用名称或包名
  Future<RepositoryResult<List<IAppInfo>>> searchApps(String keyword);

  /// 批量添加应用
  Future<RepositoryResult<void>> addApps(List<IAppInfo> apps);

  /// 清空所有应用
  Future<RepositoryResult<void>> clearAll();

  /// 获取应用总数
  Future<int> getCount();

  /// 检查应用是否存在
  Future<bool> exists(String packageName);
}
