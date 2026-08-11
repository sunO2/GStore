/// 更新检测日志模型（core 层，供 UpdateManager 输出检测过程日志）
library;

import 'package:get/get.dart';

/// 检测日志级别（决定颜色规则）
enum CheckLogLevel {
  /// 信息（检测过程）
  info,

  /// 已安装应用信息
  installed,

  /// 发现更新
  update,

  /// 无更新
  none,

  /// 跳过（未安装 / 无版本信息）
  skip,

  /// 错误
  error,
}

/// 单条检测日志
class CheckLogEntry {
  final CheckLogLevel level;
  final String text;
  final DateTime time;

  CheckLogEntry({
    required this.level,
    required this.text,
    DateTime? time,
  }) : time = time ?? DateTime.now();

  String get timeText {
    final h = time.hour.toString().padLeft(2, '0');
    final m = time.minute.toString().padLeft(2, '0');
    final s = time.second.toString().padLeft(2, '0');
    return '$h:$m:$s';
  }
}

/// 检测进度回调数据（供更新页滚轮/图标/进度展示）
class UpdateCheckProgress {
  /// 渠道内应用 ID
  final String appId;

  /// 应用名称（检测后可得；AddedAppInfo 精简版无 appName，检测前用 appId 占位）
  final String appName;

  /// 图标 URL（检测后可得）
  final String? iconUrl;

  /// 当前索引（0-based）
  final int index;

  /// 总数
  final int total;

  /// 是否已有结果（检测完成）
  final bool hasResult;

  const UpdateCheckProgress({
    required this.appId,
    required this.appName,
    this.iconUrl,
    required this.index,
    required this.total,
    this.hasResult = false,
  });
}

/// 检测日志流（UpdateManager → UpdateLogic → UpdateState.checkLog）
class UpdateLogController extends GetxController {
  /// 日志列表（页面订阅后追加到本地 checkLog）
  final RxList<CheckLogEntry> logs = <CheckLogEntry>[].obs;

  void add(CheckLogLevel level, String text) {
    logs.add(CheckLogEntry(level: level, text: text));
  }

  void clear() => logs.clear();
}
