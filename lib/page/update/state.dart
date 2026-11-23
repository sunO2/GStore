import 'package:gstore/core/download/model/download_task.dart';
import 'package:gstore/core/update/app_update_info.dart';
import 'package:gstore/core/update/update_log.dart';

export 'package:gstore/core/update/update_log.dart'
    show CheckLogLevel, CheckLogEntry;

/// 应用更新页状态（Riverpod 不可变 state）。
class UpdateState {
  /// 可更新应用列表
  final List<AppUpdateInfo> updateList;

  /// 是否正在检测
  final bool isLoading;

  /// 错误信息（null 表示无错误）
  final String? errorMessage;

  /// 检测进度
  final int checkedCount;

  /// 总应用数
  final int totalCount;

  /// 正在更新的应用键集合（`channelId:appId`；支持多个应用并发下载）
  final Set<String> updatingAppKeys;

  /// 各应用当前的下载任务（`channelId:appId` → 任务；用于并发进度展示）
  final Map<String, DownloadTask> downloadTasks;

  /// 当前正在检测的应用名（用于滚动动画展示）
  final String? checkingAppName;

  /// 当前正在检测的应用图标 URL（用于 loading 叠加展示）
  final String? checkingIconUrl;

  /// 待检测应用名列表（滚轮展示顺序）
  final List<String> checkList;

  /// 当前正在检测的应用在列表中的索引
  final int checkIndex;

  /// 检测日志（按时间顺序追加）
  final List<CheckLogEntry> checkLog;

  /// 检测是否已完成（无更新时停留在检测页展示日志）
  final bool checkFinished;

  /// 用户为各应用选择的 APK 文件名（`{channelId}:{appId}` → 文件名；空 = 未选/默认规则）
  /// 默认选中 = core 重新投影后的 latestDownload（或用户本次选择）
  final Map<String, String> selectedApkName;

  /// 是否显示检测日志页（有更新时手动切换：true=日志页 / false=更新列表）
  final bool showLog;

  const UpdateState({
    this.updateList = const [],
    this.isLoading = false,
    this.errorMessage,
    this.checkedCount = 0,
    this.totalCount = 0,
    this.updatingAppKeys = const {},
    this.downloadTasks = const {},
    this.checkingAppName,
    this.checkingIconUrl,
    this.checkList = const [],
    this.checkIndex = 0,
    this.checkLog = const [],
    this.checkFinished = false,
    this.selectedApkName = const {},
    this.showLog = false,
  });

  UpdateState copyWith({
    List<AppUpdateInfo>? updateList,
    bool? isLoading,
    String? errorMessage,
    bool clearErrorMessage = false,
    int? checkedCount,
    int? totalCount,
    Set<String>? updatingAppKeys,
    Map<String, DownloadTask>? downloadTasks,
    String? checkingAppName,
    String? checkingIconUrl,
    List<String>? checkList,
    int? checkIndex,
    List<CheckLogEntry>? checkLog,
    bool? checkFinished,
    Map<String, String>? selectedApkName,
    bool? showLog,
  }) {
    return UpdateState(
      updateList: updateList ?? this.updateList,
      isLoading: isLoading ?? this.isLoading,
      errorMessage:
          clearErrorMessage ? null : errorMessage ?? this.errorMessage,
      checkedCount: checkedCount ?? this.checkedCount,
      totalCount: totalCount ?? this.totalCount,
      updatingAppKeys: updatingAppKeys ?? this.updatingAppKeys,
      downloadTasks: downloadTasks ?? this.downloadTasks,
      checkingAppName: checkingAppName ?? this.checkingAppName,
      checkingIconUrl: checkingIconUrl ?? this.checkingIconUrl,
      checkList: checkList ?? this.checkList,
      checkIndex: checkIndex ?? this.checkIndex,
      checkLog: checkLog ?? this.checkLog,
      checkFinished: checkFinished ?? this.checkFinished,
      selectedApkName: selectedApkName ?? this.selectedApkName,
      showLog: showLog ?? this.showLog,
    );
  }

  /// 该应用是否正在更新（按 `channelId:appId` 复合键判断）
  bool isUpdating(AppUpdateInfo info) =>
      updatingAppKeys.contains(updateSelectionKey(info));

  /// 该应用当前的下载任务（无则 null）
  DownloadTask? downloadFor(AppUpdateInfo info) =>
      downloadTasks[updateSelectionKey(info)];

  /// 是否有任一应用正在更新（用于禁用“全部更新”按钮）
  bool get isUpdatingAny => updatingAppKeys.isNotEmpty;
}
