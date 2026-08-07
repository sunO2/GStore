import 'package:get/get.dart';
import 'package:installed_apps/installed_apps.dart';
import 'package:gstore/core/aggregate/AppAggregatorManager.dart';
import 'package:gstore/core/channel/ChannelManager.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/utils/unit.dart';

/// 红点键（未来可扩展：新增枚举值即可）
enum BadgeKey {
  /// 应用更新数量
  appUpdate('app_update'),

  /// 数据库版本更新（0/1）
  dbUpdate('db_update');

  final String code;
  const BadgeKey(this.code);
}

/// 红点服务
/// 统一管理各功能入口的红点状态，供 UI 通过 Obx 监听
class BadgeService extends GetxService {
  static BadgeService get instance => Get.find<BadgeService>();

  /// 红点数据（key -> 数量，>0 显示红点）
  final RxMap<String, int> _badges = <String, int>{}.obs;

  /// 红点数据（供 Obx 监听）
  RxMap<String, int> get badges => _badges;

  /// 获取指定红点数量
  int countOf(BadgeKey key) => _badges[key.code] ?? 0;

  /// 是否有红点
  bool hasBadge(BadgeKey key) => (countOf(key) > 0);

  /// 设置红点数量（0 表示清除）
  void setBadge(BadgeKey key, int count) {
    if (count <= 0) {
      _badges.remove(key.code);
    } else {
      _badges[key.code] = count;
    }
  }

  /// 增加红点数量
  void addBadge(BadgeKey key, int count) {
    setBadge(key, countOf(key) + count);
  }

  /// 清除指定红点
  void clearBadge(BadgeKey key) {
    _badges.remove(key.code);
  }

  /// 清空所有红点
  void clearAll() {
    _badges.clear();
  }

  /// 启动后检测所有红点来源
  /// 后台异步执行，不阻塞 UI
  Future<void> checkAll() async {
    await Future.wait([
      _checkAppUpdateBadge(),
      _checkDbUpdateBadge(),
    ]);
  }

  /// 检测应用更新红点（已添加且已安装的应用有更新数量）
  Future<void> _checkAppUpdateBadge() async {
    try {
      final aggregator = AppAggregatorManager.instance;
      final manager = ChannelManager.instance;
      final addedApps = await aggregator.getAllAddedApps();

      int count = 0;
      for (final added in addedApps) {
        try {
          final channelType = ChannelType.fromCode(added.channelId);
          if (channelType == null) continue;
          final channel = manager.getChannel(channelType);
          if (channel == null) continue;

          final checkResult = await channel.checkAppUpdate(added.appId);
          if (!checkResult.success || checkResult.data == null) continue;
          final check = checkResult.data!;

          final packageName = check.packageName.trim().isNotEmpty
              ? check.packageName.trim()
              : added.appId;
          final installed = await InstalledApps.getAppInfo(packageName);
          final installedVersion = installed?.versionName;
          final latestVersion = check.latestVersion;

          if (installedVersion != null &&
              latestVersion != null &&
              compareVersion(installedVersion, latestVersion) == 1) {
            count++;
          }
        } catch (e) {
          // 单个应用失败不影响整体
        }
      }

      setBadge(BadgeKey.appUpdate, count);
      appLog.info('BadgeService: 应用更新红点数量 = $count');
    } catch (e) {
      appLog.error('BadgeService: 检测应用更新红点失败 - $e');
    }
  }

  /// 检测数据库版本更新红点
  Future<void> _checkDbUpdateBadge() async {
    try {
      final info = await Get.find<DbManager>().checkUpdateInfo('gstore');
      final hasUpdate = info != null;
      setBadge(BadgeKey.dbUpdate, hasUpdate ? 1 : 0);
      appLog.info('BadgeService: 数据库更新红点 = $hasUpdate');
    } catch (e) {
      appLog.error('BadgeService: 检测数据库更新红点失败 - $e');
    }
  }
}
