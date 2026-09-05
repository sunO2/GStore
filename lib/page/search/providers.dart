import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/db/apps/AppInfoDatabase.dart';

/// 应用信息数据库（经模块注册表取 DbManager，避免 GetX 服务定位）。
///
/// 渐进迁移说明：DbManager 由 db 模块经 `context.bindService` 以具体类型注册进
/// [ModuleManager]（非 GetX 容器），故这里直接 [ModuleManager.instance.get]。
/// db 模块下线时为 null，页面按空结果处理。
final searchDatabaseProvider = Provider<AppInfoDatabase?>((ref) {
  return ModuleManager.instance.get<DbManager>()?.dbRepositroies['gstore']?.db;
});

/// 搜索结果（分类浏览/关键词搜索共用，Riverpod 版替代原 GetxController）。
class SearchNotifier extends Notifier<List<AppInfo>> {
  Timer? _searchDebounce;

  /// 查询序列号：每次输入自增，防抖回调/异步返回后仅最新序列生效，
  /// 丢弃过期查询结果（等价原逻辑「输入已变化，丢弃过期结果」）。
  int _querySeq = 0;

  @override
  List<AppInfo> build() {
    ref.onDispose(() => _searchDebounce?.cancel());
    return const [];
  }

  /// 分类浏览入口参数已通过 GoRouter extra 由页面传入（go_router 无
  /// Get.arguments）。分类浏览为一次性加载（页面 initState 调用）。
  Future<void> loadCategory(AppCategory category) async {
    final db = ref.read(searchDatabaseProvider);
    final list = await db?.dao.queryCategory(category.id);
    if ((list?.isNotEmpty ?? false) && list != null) {
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
      final db = ref.read(searchDatabaseProvider);
      final searchList = await db?.dao.search(input);
      if (seq != _querySeq) return; // 输入已变化，丢弃过期结果
      if (searchList?.isNotEmpty ?? false) {
        state = searchList!;
      } else {
        state = const [];
      }
    });
  }
}

final searchProvider =
    NotifierProvider<SearchNotifier, List<AppInfo>>(SearchNotifier.new);
