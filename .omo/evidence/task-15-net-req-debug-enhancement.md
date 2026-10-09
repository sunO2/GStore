# Task 15 — 各分区搜索 / 筛选 / 排序 — Evidence

Plan: `.omo/plans/net-req-debug-enhancement.md` todo 15
Commit: `feat(request-debug): search, filter, sort sections`

## What changed

| File | Change |
| --- | --- |
| `lib/core/request_debug/debug_search.dart` (new) | 纯函数搜索 / 过滤 / 排序模块：`DebugSortOrder`、`debugQueryMatches`、`debugRequestMatches`、`filterDebugCollections` / `sortDebugCollections`、`filterDebugHistory` / `sortDebugHistory`、`filterDebugEnvironments` / `sortDebugEnvironments`、`filterDebugRules` / `sortDebugRules`。全部无副作用、不改输入、空查询返回副本、无匹配返回空、绝不抛异常。 |
| `lib/core/request_debug/request_debug.dart` | 导出 `debug_search.dart`（统一纯逻辑出口）。 |
| `lib/page/request_debug/search_sort_bar.dart` (new) | 分区共用搜索框 + 排序菜单（复用共享 `AppTextField`，**未修改**；颜色 / 字号全取主题令牌）。 |
| `lib/page/request_debug/collection_section.dart` | 集合树接入搜索 / 排序；按名称命中保留整棵子树、请求命中仅留命中项；空结果空态 `未找到匹配的集合`。 |
| `lib/page/request_debug/history_section.dart` | 历史接入搜索 / 排序；空结果空态 `未找到匹配的历史`。 |
| `lib/page/request_debug/environment_section.dart` | 环境接入搜索 / 排序；空结果空态 `未找到匹配的环境`。 |
| `lib/page/request_debug/rules_section.dart` | 改写规则接入搜索 / 排序；空结果空态 `未找到匹配的规则`。 |
| `test/request_debug_search_test.dart` (new) | 纯函数表驱动用例 + 四分区 widget 搜索 / 空态 / 清空 / 无匹配用例 + 集合排序菜单冒烟。 |

**CRUD 语义未变**：过滤 / 排序只作用于 `store` 返回的列表副本，所有增删改仍走原 `RequestDebugStore` 调用；`save()` 时机与既有分区一致。

## Failing-first (RED)

Command:
```
LD_LIBRARY_PATH=/tmp flutter test test/request_debug_search_test.dart
```
Result (module skeleton = 全部 `UnimplementedError`; widgets 尚无搜索框，18 用例失败):
```
00:00 +0: loading .../test/request_debug_search_test.dart
00:00 +0 -1: filterDebugCollections 空查询返回全部（副本，不改输入） [E]
  UnimplementedError
  package:gstore/core/request_debug/debug_search.dart 65:3  filterDebugCollections
  test/request_debug_search_test.dart 130:19                main.<fn>.<fn>
...
00:01 +0 -18: Some tests failed.

Failing tests:
  .../test/request_debug_search_test.dart: filterDebugCollections 子文件夹命中：保留祖先链（层级）
  .../test/request_debug_search_test.dart: filterDebugCollections 无匹配返回空，不抛
  .../test/request_debug_search_test.dart: filterDebugCollections 空查询返回全部（副本，不改输入）
  .../test/request_debug_search_test.dart: filterDebugCollections 请求命中：只剩该请求与所属集合
  ... and 14 more
```
原始日志：`.omo/evidence/task-15-red.txt`。

## GREEN

```
LD_LIBRARY_PATH=/tmp flutter test test/request_debug_search_test.dart
...
00:01 +18: 改写规则分区搜索 输入关键字只剩匹配；清空恢复；无匹配空态且不崩
00:01 +19: All tests passed!
```

相邻套件（四分区 CRUD / 页面回归，56 用例）:
```
LD_LIBRARY_PATH=/tmp flutter test \
  test/request_debug_editor_test.dart test/request_debug_rules_test.dart \
  test/request_debug_history_test.dart test/request_debug_page_test.dart
...
00:11 +56: All tests passed!
```

静态门:
```
LD_LIBRARY_PATH=/tmp dart analyze lib/
729 issues found.   # 全部为既有 info（与基线一致，见 task-14 证据）
# 改动文件过滤：
dart analyze lib/ | grep -E "debug_search.dart|search_sort_bar.dart|collection_section.dart|history_section.dart|environment_section.dart|rules_section.dart|request_debug.dart"
NO ISSUES IN CHANGED FILES
```

## Assertions proven

1. **纯函数不副作用**：空查询返回输入副本（`isNot(same(input))`）；过滤 / 排序返回新列表。
2. **集合树**：请求命中仅留命中请求与所属集合；集合名命中保留整棵子树；子文件夹命中保留祖先链；无匹配返回空且不抛。
3. **排序**：集合同级排序保持父子层级（`a`→`z`→`b` for asc）；历史 `original` = 最新在前、`nameAsc` 按 URL；环境 / 规则按名称 / URL。
4. **widget（四分区）**：输入关键字后只剩匹配项；无匹配显示空态（`未找到匹配的集合 / 历史 / 环境 / 规则`）且 `takeException()` 为 `null`；清空查询后恢复全量。
5. **排序接线冒烟**：集合分区打开排序菜单选 `nameAsc` 后根集合纵向顺序由 `Beta, Alpha` 变为 `Alpha, Beta`。

## Notes

- 第 19 个用例（集合排序菜单冒烟）在实现转 GREEN 后补写，作为排序**接线**冒烟，非 RED 阶段用例；搜索验收四项（匹配 / 空态 / 清空 / 无匹配不崩）均由 RED 阶段用例覆盖。
- 未修改任何共享设计组件（`AppTextField` 仅使用）；未新增 `showDialog` / 手写 bottom sheet；未改 `pubspec.yaml` / 版本号；未提交 `dist/`。
