import 'package:get/get.dart';
import 'package:gstore/db/apps/AppInfo.dart';

class SearchState {
  /// 搜索结果（Rx 保证 UI 始终能获取最新值，避免单订阅流数据丢失）
  final RxList<AppInfo> searchList = <AppInfo>[].obs;

  SearchState() {
    ///Initialize variables
  }
}
