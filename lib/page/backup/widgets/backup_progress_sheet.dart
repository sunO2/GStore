import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';

import 'package:gstore/core/core.dart';
import 'package:gstore/core/design/progress_log_sheet.dart';

/// 备份/恢复动画进度面板（[ProgressLogSheet] 的备份皮肤）。
///
/// 逐行日志 + 自动滚动 + 分级颜色 + 状态图标，与 GitHub 登录检查等项目
/// 诊断面板共用同一套视觉。
class BackupProgressSheet extends StatelessWidget {
  /// 面板标题（如 '备份到网盘' / '从网盘恢复备份'）
  final String title;

  /// 任务闭包：接收 onLog 回调输出进度日志，完成或异常时结束
  final Future<void> Function(BackupLogCallback onLog) task;

  const BackupProgressSheet({
    super.key,
    required this.title,
    required this.task,
  });

  @override
  Widget build(BuildContext context) {
    return ProgressLogSheet(
      title: title,
      icon: TablerIcons.cloud,
      task: task,
    );
  }
}
