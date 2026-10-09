# Task 22 — 抓包列表分页 / 排序 / 单删 / 分享 + 准确计数与筛选 / 导出

Plan: `.omo/plans/net-req-debug-enhancement.md` todo 22 `[contract-gated]`
Commit message: `feat(proxy-ui): paginate, sort, delete, share captures`

## 0. STEP 0 — 游标原语验证（决定性）

**结论：游标语义正确（pass）。未改动 Rust 行为，仅新增 characterization 测试；后续全部为 Dart 层改动。**

新增到 `rust/gstore_mod_proxy/src/captures.rs` 的 `mod tests`：

`captures_snapshot_cursor_semantics_characterization`

它固化当前 `CaptureStore::snapshot()` 契约：

- `since = 0` 返回**最旧**一页，按 `recordId` 升序（“默认返回最旧 200”是**契约行为**，非 bug）。
- 下一页必须传**本页最后一条 `recordId`** 作为 `since`，**不是** `nextCursor`。
- `nextCursor` 是从不回收的高水位（high-water mark），不等于本页尾 id。
- 页间不相交（无重复 `recordId`）；越过高水位返回空页 = 停止信号。

Raw（`cargo test captures_snapshot_cursor_semantics_characterization`，cwd `rust/gstore_mod_proxy`）：

```
running 1 test
test captures::tests::captures_snapshot_cursor_semantics_characterization ... ok
test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 521 filtered out; finished in 0.00s
```

→ characterization **通过**，游标原语未损坏；**不修改 Rust 逻辑**；分页在 Dart 请求构建层实现
（以“本页最后 `recordId`”为游标）。原“最旧 200”问题的根因是 Dart 页**只拉一页且从不翻页**，
故永远看不到更“新”的记录。

## 1. TDD — failing test first (RED)

先写 `test/proxy_requests_pagination_test.dart`，再改 `proxy_requests_page.dart`。
原始 RED（`LD_LIBRARY_PATH=/tmp flutter test test/proxy_requests_pagination_test.dart`）：

```
00:01 +2 -3: 长按：复制域名与分享（剪贴板）可用
  The finder "Found 0 widgets with key [<'row_action_copy_host'>]: []" (used in a call to "tap()")
  could not find any matching widgets.
...
00:02 +2 -5: Some tests failed.

Failing tests:
  .../test/proxy_requests_pagination_test.dart: 单删：长按孤儿抓包行删除，列表与计数（已加载/保留）同步更新
  .../test/proxy_requests_pagination_test.dart: 导出遵循当前筛选：network 过滤器被转发到 requests.export
  .../test/proxy_requests_pagination_test.dart: 排序：切换到「最新优先」后行顺序按时间倒序且稳定
  .../test/proxy_requests_pagination_test.dart: 游标分页：加载到第 2 页并按 recordId 去重，计数=已加载/保留
  .../test/proxy_requests_pagination_test.dart: 长按：复制域名与分享（剪贴板）可用
```

（2 个纯函数用例先绿，因为纯函数库 `proxy_requests_paging.dart` 与测试同批落地；5 个页面行为用例
为真正的 RED。）

## 2. Implementation

- **新 `lib/page/proxy/proxy_requests_paging.dart`（纯函数）**：
  - `mergeById(existing, incoming, idOf)`：跨页去重、保留首现者；
  - `stableSortBy(items, compare)`：以下标兜底比较器，保证相等键的**稳定**顺序（Dart `List.sort` 不稳定）。
- **`lib/page/proxy/proxy_requests_page.dart`**：
  - 分页：累计 `_requests` / `_captures`（`recordId` 去重）。`_reload()` 从 `cursor=0` 起
    **前向翻页到耗尽**（`hasMore = 满页 && 尾 id < nextCursor`，上限 `_maxAutoPages=64`）；
    `_poll()` 以**当前累计尾 `recordId`** 为游标只拉增量（实时脏信号 / 2s 兜底 / 加载更多）；
    首屏与筛选变化走 `_reload`，实时走 `_poll`。前端翻页游标只用“本页尾 id”，**从不误用
    `nextCursor`**。续页时显示「加载更多」。
  - 排序：AppBar sort 菜单（默认 / 最新优先 / 最早优先 / 按大小），使用 `stableSortBy`。
  - 单删：长按行 → 统一 `AppSheet` 动作 → `showConfirmSheet(isDangerous: true)` →
    `captures.delete`（复用注入缝 `captureDeleteFacade`，详情页也复用同一门面）→ 乐观移除 +
    `_reload(silent:true)` 刷新计数。
  - 长按复制 / 分享：复制域名、复制 URL、分享（无新依赖 → 复制可分享文本摘要到剪贴板）。
  - 计数：`共 N 条`（N = 当前**已加载**去重行数）+ `保留 请求 R · 抓包 C`
    （`retained`，来自契约；**契约无 `total`，UI 不声称“真实总数”**）。
  - 筛选：`network` 现同时转发到 `requests.get`（此前仅本地过滤）；搜索 / 其它本地筛选作用于
    **整个已加载结果集**（该集由前向翻页拉全到保留上限）。
  - 导出：`requests.export` 的 `filter` 由当前筛选构建（含 `network` / `outbound` / `sinceMs`），
    即导出仅含被转发筛选命中的结果。
- 设计系统：仅 `Theme` 令牌 / `AppLoading` / `ColoredAliIcon` / `AppDialogs`/`AppSheet`；
  危险删除走 `showConfirmSheet(isDangerous: true)`；无 `showDialog` / 手写 bottom sheet。

### 诚实边界（不夸大）

- 契约 `requests.export` 的 `filter` 只接受 `domain/uid/network/outbound/sinceMs`；`method`/
  `statusClass`/`protocol`/文本搜索**不在契约内**，无法转发（加 `total` 或导出文本筛选均属 C5 契约改动，
  本 todo **不做**）。本 todo 保证**可表达筛选**（network/outbound/sinceMs）随导出下发，且本地筛选
  作用于全量已加载集。
- `retained` 是后端保留计数，不是“命中筛选的真实总数”。

## 3. GREEN — T22 acceptance

`LD_LIBRARY_PATH=/tmp flutter test test/proxy_requests_pagination_test.dart`

```
00:00 +0: 纯函数：mergeById / stableSortBy mergeById 跨页去重且保留首现顺序
00:00 +1: 纯函数：mergeById / stableSortBy stableSortBy 对相等键保持原始相对顺序
00:00 +2: 游标分页：加载到第 2 页并按 recordId 去重，计数=已加载/保留
00:00 +3: 排序：切换到「最新优先」后行顺序按时间倒序且稳定
00:01 +4: 单删：长按孤儿抓包行删除，列表与计数（已加载/保留）同步更新
00:01 +5: 长按：复制域名与分享（剪贴板）可用
00:01 +6: 导出遵循当前筛选：network 过滤器被转发到 requests.export
00:02 +7: All tests passed!
```

分页用例的假门面**故意在第 2 页重叠 `recordId=200`**（原始追加 231）→ 断言 `共 230 条`，
证明去重真实生效，而非依赖后端恰好不重叠。

## 4. Required regression suites (green)

`LD_LIBRARY_PATH=/tmp flutter test test/proxy_requests_page_test.dart
test/proxy_requests_facade_test.dart test/proxy_capture_detail_page_test.dart
test/proxy_capture_typed_bindings_test.dart`

```
00:04 +29: All tests passed!            (proxy_requests_page_test)
00:05 +24: All tests passed!            (facade + detail + typed bindings)
```

（合并再跑：7 + 29 = `00:05 +36: All tests passed!`）

## 5. Rust full suite (touched Rust)

`cargo test`（cwd `rust/gstore_mod_proxy`；该 crate 非 workspace，`-p` 不可用）

```
test result: ok. 518 passed; 0 failed; 4 ignored; 0 measured; 0 filtered out; finished in 53.55s
test result: ok. 1 passed; 0 failed; 0 ignored; ... (host_dlopen)
test result: ok. 1 passed; 0 failed; 0 ignored; ... (mitm_spike)
```

## 6. Static analysis

`dart analyze lib/page/proxy/proxy_requests_page.dart
lib/page/proxy/proxy_requests_paging.dart test/proxy_requests_pagination_test.dart`

```
No issues found!
```

`dart analyze lib/ | grep -E "proxy_requests_page|proxy_requests_paging"` → 无输出（改动文件无新增问题；
全仓 729 条 info 为既有，未触及）。

## 7. Scope / guardrails

- 契约未改（已冻结）：无新增字段 / 无 `total`；「真实总数」不在 UI 声称。
- Rust 仅新增 characterization 测试；无行为改动。
- 无新依赖；`pubspec.yaml` / 版本未改。
- 未改共享设计组件；无禁用弹层；危险删除走 `showConfirmSheet(isDangerous: true)`。
- `dist/`（未跟踪、既有）排除在暂存之外。
