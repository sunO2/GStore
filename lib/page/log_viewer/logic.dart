import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:gstore/core/logger/LogManager.dart';
import 'state.dart';

class LogViewerLogic extends GetxController {
  final LogViewerState state = LogViewerState();

  /// 日志管理器
  final LogManager _logManager = LogManager.instance;

  @override
  void onInit() {
    super.onInit();
    // 添加初始日志
    _logManager.info('日志查看器已打开');
  }

  /// 清空日志
  void clearLogs() {
    _logManager.clear();
  }

  /// 切换自动滚动
  void toggleAutoScroll() {
    state.autoScroll.value = !state.autoScroll.value;
  }

  /// 设置日志级别筛选
  void setLogLevel(LogLevel level) {
    state.selectedLevel.value = level;
  }

  /// 获取过滤后的日志
  List<LogEntry> getFilteredLogs() {
    final logs = _logManager.logs;
    final level = state.selectedLevel.value;

    if (level == LogLevel.all) {
      return logs.toList();
    }
    return logs.where((log) => log.level == level).toList();
  }

  /// 导出日志
  void exportLogs() {
    final text = _logManager.exportToText();

    // TODO: 实现剪贴板功能
    Get.snackbar(
      '导出日志',
      '已导出 ${_logManager.logs.length} 条日志',
      icon: Icon(Icons.check_circle, color: Colors.green),
      duration: const Duration(seconds: 2),
    );
  }
}
