import 'package:get/get.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';
import 'package:gstore/core/model/IDetailInfo.dart';
import 'package:gstore/http/download/DownloadStatus.dart';

/// 可更新的应用信息
class AppUpdateInfo {
  /// 来源渠道
  final String channelId;

  /// 应用 ID（渠道内原始 ID）
  final String appId;

  /// 应用名称
  final String appName;

  /// 图标 URL
  final String? iconUrl;

  /// 包名
  final String packageName;

  /// 已安装版本
  final String installedVersion;

  /// 最新版本
  final String latestVersion;

  /// 最新版本的下载信息
  final DownloadInfo latestDownload;

  /// 完整详情（用于下载策略上下文）
  final IDetailInfo detail;

  AppUpdateInfo({
    required this.channelId,
    required this.appId,
    required this.appName,
    this.iconUrl,
    required this.packageName,
    required this.installedVersion,
    required this.latestVersion,
    required this.latestDownload,
    required this.detail,
  });

  /// 渠道显示名称
  String get channelName =>
      ChannelType.fromCode(channelId)?.description ?? channelId;
}

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
