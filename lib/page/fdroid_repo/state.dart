/// F-Droid 仓库管理页面状态
library;

import 'package:get/get.dart';
import 'package:gstore/core/fdroid/FdroidRepoModels.dart';

/// F-Droid 仓库管理状态
class FdroidRepoState {
  /// 可用的源列表
  final RxList<FdroidSource> sources = <FdroidSource>[].obs;

  /// 当前选中的源
  final Rx<FdroidSource?> currentSource = Rx<FdroidSource?>(null);

  /// 是否正在加载
  final RxBool isLoading = false.obs;

  /// 加载进度 (0-100)
  final RxDouble loadingProgress = 0.0.obs;

  /// 最后的错误信息
  final RxnString errorMessage = RxnString(null);

  /// 数据库统计信息
  final RxMap<String, int> statistics = <String, int>{}.obs;

  /// 是否有更新可用
  final RxBool hasUpdate = false.obs;

  /// 当前版本
  final RxInt currentVersion = 0.obs;

  /// 最新版本
  final RxInt latestVersion = 0.obs;

  /// 搜索结果
  final RxList<FdroidApp> searchResults = <FdroidApp>[].obs;

  /// 是否正在搜索
  final RxBool isSearching = false.obs;

  FdroidRepoState();
}
