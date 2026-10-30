import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 下载「可能有未完成任务」的**廉价提示**。
///
/// 冷启动时下载模块应保持卸载（不 dlopen、不建核心 DB、不跑重启恢复），但
/// 「重启后恢复未完成任务」仍必须工作。判断是否需要恢复只需一个持久化布尔值：
/// 由 [DownloadTaskWatcher] 在任务进入进行中/排队/暂停时 [mark]，在所有已跟踪
/// 任务都到达终态后 [clear]。启动链在放行首屏后只读这一个 hint，命中才在后台
/// 拉起模块。
///
/// 它刻意不触碰模块与核心 DB：读一个 SharedPreferences 键比重载模块便宜几个
/// 数量级。hint 是**乐观**的——陈旧（stale）的 `true` 最多多花一次后台模块加载，
/// 永远不会造成正确性问题；漏写也只会在下次启动时少一次恢复（任务仍在核心 DB 里，
/// 一旦用户打开下载页/发起新下载就会重新挂上模块）。
class DownloadPendingHint {
  DownloadPendingHint._();

  /// 存储键（带版本后缀，语义变化时可平滑换键）。
  static const String storageKey = 'download_pending_hint_v1';

  /// 标记「可能还有未完成任务」。
  static Future<void> mark() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(storageKey, true);
  }

  /// 清除提示（所有已跟踪任务都到达终态）。
  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(storageKey);
  }

  /// 读取提示；读失败按「无未完成任务」处理（绝不阻塞/搞崩启动）。
  static Future<bool> hasPending() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(storageKey) ?? false;
    } catch (error) {
      debugPrint('DownloadPendingHint: 读取未完成提示失败（按无未完成处理） - $error');
      return false;
    }
  }
}
