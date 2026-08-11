import 'package:get/get.dart';
import 'package:gstore/core/update/app_update_info.dart';
import 'package:gstore/core/update/update_log.dart';
import 'package:gstore/http/download/DownloadStatus.dart';

export 'package:gstore/core/update/update_log.dart'
    show CheckLogLevel, CheckLogEntry;

class UpdateState {
  /// 可更新应用列表
  final RxList<AppUpdateInfo> updateList = <AppUpdateInfo>[].obs;

  /// 是否正在检测
  final RxBool isLoading = false.obs;

  /// 错误信息（null 表示无错误）
  final RxnString errorMessage = RxnString();

  /// 检测进度
  final RxInt checkedCount = 0.obs;

  /// 总应用数
  final RxInt totalCount = 0.obs;

  /// 正在更新的应用 ID
  final RxnString updatingAppId = RxnString();

  /// 当前下载进度
  final Rxn<DownloadStatus> currentDownload = Rxn<DownloadStatus>();

  /// 当前正在检测的应用名（用于滚动动画展示）
  final RxnString checkingAppName = RxnString();

  /// 当前正在检测的应用图标 URL（用于 loading 叠加展示）
  final RxnString checkingIconUrl = RxnString();

  /// 待检测应用名列表（滚轮展示顺序）
  final RxList<String> checkList = <String>[].obs;

  /// 当前正在检测的应用在列表中的索引
  final RxInt checkIndex = 0.obs;

  /// 检测日志（按时间顺序追加）
  final RxList<CheckLogEntry> checkLog = <CheckLogEntry>[].obs;

  /// 检测是否已完成（无更新时停留在检测页展示日志）
  final RxBool checkFinished = false.obs;

  /// 追加一条检测日志
  void addLog(CheckLogLevel level, String text) {
    checkLog.add(CheckLogEntry(level: level, text: text));
  }

  /// 重置检测进度
  void resetCheckProgress() {
    checkedCount.value = 0;
    totalCount.value = 0;
    errorMessage.value = null;
    checkList.clear();
    checkIndex.value = 0;
    checkLog.clear();
    checkFinished.value = false;
  }
}
