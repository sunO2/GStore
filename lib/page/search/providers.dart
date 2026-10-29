import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gstore/core/catalog/catalog_facade.dart';
import 'package:gstore/core/event/live_refresh.dart';
import 'package:gstore/core/model/AppSummary.dart';
import 'package:gstore/db/apps/AppInfo.dart';

/// 目录门面（catalog 归 Rust core：`CatalogFacade` 恒走 `FrbCatalogBackend`）。
///
/// 搜索/分类读路径与写路径同源，不再直读旧 `apps.db`。
final catalogFacadeProvider = Provider<CatalogFacade>((ref) {
  return CatalogFacade.instance;
});

/// 搜索结果（分类浏览/关键词搜索共用，Riverpod 版替代原 GetxController）。
class SearchNotifier extends Notifier<List<AppSummary>> {
  Timer? _searchDebounce;

  /// 渠道/目录变化（Rust 上行）的防抖订阅：一串事件只重跑一次当前查询。
  LiveRefreshSubscription? _liveRefresh;

  /// 当前生效的加载入口：最近一次 `loadCategory`（分类浏览）。
  AppCategory? _lastCategory;

  /// 当前生效的加载入口：最近一次非空关键词（关键词搜索）。
  String _lastInput = '';

  /// 查询序列号：每次输入自增，防抖回调/异步返回后仅最新序列生效，
  /// 丢弃过期查询结果（等价原逻辑「输入已变化，丢弃过期结果」）。
  int _querySeq = 0;

  @override
  List<AppSummary> build() {
    ref.onDispose(() {
      _searchDebounce?.cancel();
      _liveRefresh?.dispose();
      _liveRefresh = null;
    });
    // 渠道/目录变化 → 防抖重跑「当前加载入口」（分类浏览或关键词搜索）。
    _liveRefresh = LiveRefreshSubscription(onRefresh: _onLiveRefresh);
    return const [];
  }

  /// 分类浏览入口参数已通过 GoRouter extra 由页面传入（go_router 无
  /// Get.arguments）。分类浏览为一次性加载（页面 initState 调用）。
  Future<void> loadCategory(AppCategory category) async {
    _lastCategory = category;
    _lastInput = '';
    final list = await ref.read(catalogFacadeProvider).byCategory(category.id);
    if (list.isNotEmpty) {
      state = list;
    }
  }

  /// 输入变化（页面 TextField listener 回调）：
  /// 空输入立即清空；非空防抖 200ms 后查询，过期结果丢弃。
  void onInputChanged(String input) {
    _lastInput = input;
    _lastCategory = null;
    final seq = ++_querySeq;
    if (input.isEmpty) {
      _searchDebounce?.cancel();
      state = const [];
      return;
    }

    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 200), () {
      unawaited(_runQuery(input, seq));
    });
  }

  /// 渠道/目录变化 → 防抖后重跑当前加载入口（复用既有加载路径，无新 loading UI）。
  void _onLiveRefresh() {
    final category = _lastCategory;
    if (category != null) {
      unawaited(loadCategory(category));
      return;
    }
    final input = _lastInput;
    if (input.isEmpty) return;
    final seq = ++_querySeq;
    unawaited(_runQuery(input, seq));
  }

  /// 关键词查询（防抖回调与实时刷新共用）：仅最新序列的结果写回 state。
  Future<void> _runQuery(String input, int seq) async {
    final searchList = await ref.read(catalogFacadeProvider).search(input);
    if (seq != _querySeq) return; // 输入已变化，丢弃过期结果
    if (searchList.isNotEmpty) {
      state = searchList;
    } else {
      state = const [];
    }
  }
}

final searchProvider =
    NotifierProvider<SearchNotifier, List<AppSummary>>(SearchNotifier.new);
