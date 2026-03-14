import 'package:get/get.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';
import 'package:gstore/core/model/AppDetailRequest.dart';
import 'package:gstore/core/model/IDetailData.dart';
import 'package:installed_apps/app_info.dart';

class DetailState {
  /// 请求参数（基础信息）
  AppDetailRequest? request;

  /// 应用详情信息
  final Rx<IDetailData?> detailInfo = Rx<IDetailData?>(null);

  /// 是否正在加载
  final RxBool isLoading = true.obs;

  /// 错误信息
  final RxString errorMessage = ''.obs;

  /// 已安装的应用信息
  AppInfo? installInfo;

  /// 是否正在加载详情（基础信息已显示）
  final RxBool isLoadingDetail = false.obs;

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
}
