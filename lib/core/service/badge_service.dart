import 'package:get/get.dart';
import 'package:gstore/core/core.dart';

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
    // 应用更新红点由 UpdateManager 驱动（订阅 updateList），
    // 这里仅触发一次懒检测（锁+时间窗防重），随后订阅同步
    await UpdateManagerService.instance.ensureChecked();
    _subscribeUpdateManagerService();
    await _checkDbUpdateBadge();
  }

  /// 是否已订阅 UpdateManager
  bool _subscribed = false;

  /// 订阅 UpdateManager：可更新数量变化 → 同步红点
  void _subscribeUpdateManagerService() {
    if (_subscribed) return;
    _subscribed = true;
    UpdateManagerService.instance.updateList.listen((list) {
      setBadge(BadgeKey.appUpdate, list.length);
      appLog.info('BadgeService: 应用更新红点数量 = ${list.length}');
    });
    // 立即同步当前值：updateList.listen 只响应后续变化，
    // 而启动时缓存恢复（UpdateManager.onInit → _restoreCache）可能已在订阅前完成，
    // 否则有可更新应用时红点不亮（直到下一次检测变化才出现）
    setBadge(BadgeKey.appUpdate, UpdateManagerService.instance.updateList.length);
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
