import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gstore/core/catalog/catalog_facade.dart';
import 'package:gstore/core/model/AppSummary.dart';
import 'package:gstore/db/apps/AppInfo.dart';

/// 目录门面（经 flag 路由：`catalog` 开走 Rust core，关回落旧 backend）。
///
/// 搜索/分类读路径与写路径同源，不再直读旧 `apps.db`（DbManager 下线时为
/// null 的旧路径已由门面的 legacy backend 承担）。
final catalogFacadeProvider = Provider<CatalogFacade>((ref) {
  return CatalogFacade.instance;
});

/// 搜索结果（分类浏览/关键词搜索共用，Riverpod 版替代原 GetxController）。
class SearchNotifier extends Notifier<List<AppSummary>> {
  Timer? _searchDebounce;

  /// 查询序列号：每次输入自增，防抖回调/异步返回后仅最新序列生效，
  /// 丢弃过期查询结果（等价原逻辑「输入已变化，丢弃过期结果」）。
  int _querySeq = 0;

  @override
  List<AppSummary> build() {
    ref.onDispose(() => _searchDebounce?.cancel());
    return const [];
  }

  /// 分类浏览入口参数已通过 GoRouter extra 由页面传入（go_router 无
  /// Get.arguments）。分类浏览为一次性加载（页面 initState 调用）。
  Future<void> loadCategory(AppCategory category) async {
    final list = await ref.read(catalogFacadeProvider).byCategory(category.id);
    if (list.isNotEmpty) {
      state = list;
    }
  }

  /// 输入变化（页面 TextField listener 回调）：
  /// 空输入立即清空；非空防抖 200ms 后查询，过期结果丢弃。
  void onInputChanged(String input) {
    final seq = ++_querySeq;
    if (input.isEmpty) {
      _searchDebounce?.cancel();
      state = const [];
      return;
    }

    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 200), () async {
      final searchList = await ref.read(catalogFacadeProvider).search(input);
      if (seq != _querySeq) return; // 输入已变化，丢弃过期结果
      if (searchList.isNotEmpty) {
        state = searchList;
      } else {
        state = const [];
      }
    });
  }
}

final searchProvider =
    NotifierProvider<SearchNotifier, List<AppSummary>>(SearchNotifier.new);
