import 'package:gstore/core/core.dart';
import 'package:gstore/core/aggregate/aggregate.dart';
import 'package:gstore/db/apps/AppInfo.dart';

class ApplistState {
  /// 聚合的应用列表（按添加时间排序）
  List<AggregatedAppInfo> apps = [];

  /// 过滤后的应用列表（用于显示搜索结果）
  List<AggregatedAppInfo> filteredApps = [];

  /// 搜索关键词
  final RxString searchKeyword = ''.obs;

  /// 数据库版本
  String version = "";

  /// 登录状态
  final RxInt loginStatus = (-1).obs;

  /// 是否正在加载
  final RxBool isLoading = false.obs;

  /// 错误信息
  final RxString errorMessage = ''.obs;

  /// Banner 数据缓存 Future
  Future<List<dynamic>>? bannerFuture;

  ApplistState() {
    ///Initialize variables
  }
}
