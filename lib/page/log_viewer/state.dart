import 'package:get/get.dart';
import 'package:gstore/core/logger/LogManager.dart';

class LogViewerState {
  /// 日志级别筛选
  final Rx<LogLevel> selectedLevel = LogLevel.all.obs;

  /// 自动滚动
  final RxBool autoScroll = true.obs;

  LogViewerState();
}
