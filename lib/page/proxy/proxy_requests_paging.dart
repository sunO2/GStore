/// 抓包 / 请求列表的游标分页与稳定排序纯函数（Todo 22）。
///
/// 后端 `requests.get` / `captures.get` 是**前向游标**：`cursor` 只返回
/// `recordId > cursor` 的行，按 `recordId` 升序截断到 `limit`。因此翻页必须以
/// **本页最后一条的 `recordId`** 作为下一页 `cursor`（`nextCursor` 是从不回收的
/// 高水位，不是下一页游标）。这里只做纯计算：合并去重与稳定排序，便于单测。
library;

/// 追加去重（按 [idOf] 判定同一行）：保留 [existing] 的顺序与首现者，
/// [incoming] 中未见过的 id 追加到尾部。跨页重叠时不会产生重复行。
List<T> mergeById<T>(
  List<T> existing,
  List<T> incoming,
  int Function(T item) idOf,
) {
  final seen = <int>{for (final item in existing) idOf(item)};
  final merged = List<T>.of(existing);
  for (final item in incoming) {
    if (seen.add(idOf(item))) merged.add(item);
  }
  return merged;
}

/// 稳定排序：`compare` 返回 0 的元素保持其原始相对顺序（用原始下标兜底，
/// 使比较器成为全序）。Dart 的 `List.sort` 本身不保证稳定，故不可直接用。
List<T> stableSortBy<T>(List<T> items, int Function(T a, T b) compare) {
  final indexed = List<(int, T)>.generate(
    items.length,
    (index) => (index, items[index]),
  );
  indexed.sort((a, b) {
    final byKey = compare(a.$2, b.$2);
    return byKey != 0 ? byKey : a.$1.compareTo(b.$1);
  });
  return <T>[for (final entry in indexed) entry.$2];
}
