import 'package:floor/floor.dart';
import 'package:gstore/core/channel/database/channel_added_app.dart';

/// 渠道已添加应用 DAO
@dao
abstract class ChannelAddedAppDao {
  /// 添加应用
  @Insert(onConflict: OnConflictStrategy.replace)
  Future<void> insertApp(ChannelAddedApp app);

  /// 批量添加应用
  @Insert(onConflict: OnConflictStrategy.replace)
  Future<void> insertApps(List<ChannelAddedApp> apps);

  /// 删除应用
  @Query('DELETE FROM channel_added_app WHERE appId = :appId AND channelCode = :channelCode')
  Future<void> removeApp(String appId, String channelCode);

  /// 获取指定渠道的所有应用
  @Query('SELECT * FROM channel_added_app WHERE channelCode = :channelCode ORDER BY addTime DESC')
  Future<List<ChannelAddedApp>> getAppsByChannel(String channelCode);

  /// 获取指定渠道的应用数量
  @Query('SELECT COUNT(*) FROM channel_added_app WHERE channelCode = :channelCode')
  Future<int?> getCountByChannel(String channelCode);

  /// 检查应用是否存在
  @Query('SELECT * FROM channel_added_app WHERE appId = :appId AND channelCode = :channelCode LIMIT 1')
  Future<ChannelAddedApp?> getApp(String appId, String channelCode);

  /// 清空指定渠道的所有应用
  @Query('DELETE FROM channel_added_app WHERE channelCode = :channelCode')
  Future<void> clearChannel(String channelCode);

  /// 获取所有渠道的所有应用
  @Query('SELECT * FROM channel_added_app ORDER BY addTime DESC')
  Future<List<ChannelAddedApp>> getAllApps();

  /// 获取所有应用总数
  @Query('SELECT COUNT(*) FROM channel_added_app')
  Future<int?> getTotalCount();
}
