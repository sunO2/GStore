import 'package:get/get.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';
import 'package:gstore/core/model/AppDetailRequest.dart';
import 'package:gstore/core/model/IDetailInfo.dart';
import 'package:gstore/http/download/DownloadStatus.dart';
import 'package:installed_apps/app_info.dart';

class DetailState {
  /// 请求参数（基础信息）
  AppDetailRequest? request;

  /// 应用详情信息
  final Rx<IDetailInfo?> detailInfo = Rx<IDetailInfo?>(null);

  /// 是否正在加载（改为 false，避免显示大块 loading）
  final RxBool isLoading = false.obs;

  /// 错误信息
  final RxString errorMessage = ''.obs;

  /// 已安装的应用信息（响应式变量）
  final Rx<AppInfo?> installInfo = Rx<AppInfo?>(null);

  /// 是否正在加载详情（基础信息已显示）
  final RxBool isLoadingDetail = false.obs;

  /// 当前下载状态（响应式，用于 FAB 进度显示）
  final Rx<DownloadStatus?> currentDownload = Rx<DownloadStatus?>(null);

  /// 下载列表（分块加载独立注入，null=未就绪/失败降级）
  final Rx<List<DownloadInfo>?> downloads = Rx<List<DownloadInfo>?>(null);

  /// README 内容（分块加载独立注入，null=未就绪/失败降级）
  final Rx<String?> readme = Rx<String?>(null);

  /// 下载列表区块加载中
  final RxBool downloadsLoading = false.obs;

  /// README 区块加载中
  final RxBool readmeLoading = false.obs;

  /// 统计区块加载中
  final RxBool statisticsLoading = false.obs;

  /// 更多按钮忙碌态（慢操作如切版本/切 UA 进行中，AppBar actions 响应式渲染）
  final RxBool actionBusy = false.obs;

  /// 忙碌态描述文案（如「正在切换版本…」，空串用默认提示）
  final RxString actionBusyLabel = ''.obs;

  DetailState() {
    ///Initialize variables
  }

  /// 获取当前显示的名称（优先使用详情，否则使用请求）
  String get displayName => detailInfo.value?.name ?? request?.name ?? '';

  /// 获取当前显示的图标（优先使用详情，否则使用请求）
  String get displayIcon => detailInfo.value?.icon ?? request?.icon ?? '';

  /// 获取当前显示的描述（优先使用详情，否则使用请求）
  String get displayDescription =>
      detailInfo.value?.description ?? request?.description ?? '';

  /// 获取当前显示的版本（优先使用详情）
  String? get displayVersion => detailInfo.value?.version;

  /// 是否有详情信息
  bool get hasDetailInfo => detailInfo.value != null;

  /// 是否已安装
  bool get isInstalled => installInfo.value != null;
}
