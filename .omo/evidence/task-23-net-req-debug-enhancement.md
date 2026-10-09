# Task 23 — 抓包详情增强（hex / 图片 / 解码 / 存盘 / 重发 / 瀑布 + 首次加载失败冻结修复）

Plan: `.omo/plans/net-req-debug-enhancement.md` todo 23
Commit message: `feat(proxy-ui): richer capture detail and export`
Depends on: T22（列表游标分页，commit `6c87672`）

## 0. TDD — failing test first (RED)

先写 `test/proxy_capture_detail_enhanced_test.dart`，再改生产代码。
原始 RED（`LD_LIBRARY_PATH=/tmp flutter test test/proxy_capture_detail_enhanced_test.dart`）：

```
test/proxy_capture_detail_enhanced_test.dart:258:7: Error: No named parameter with the name 'saveFile'.
      saveFile: ({
      ^^^^^^^^
lib/page/proxy/proxy_capture_detail_page.dart:117:9: Context: Found this candidate, but the arguments don't match.
  const ProxyCaptureDetailPage({
        ^^^^^^^^^^^^^^^^^^^^^^^
00:00 +0 -1: loading .../proxy_capture_detail_enhanced_test.dart [E]
  Failed to load ...: Compilation failed for testPath=.../proxy_capture_detail_enhanced_test.dart:
    test/proxy_capture_detail_enhanced_test.dart:258:7: Error: No named parameter with the name 'saveFile'.
00:00 +0 -1: Some tests failed.
```

（RED 为「新能力尚不存在」：存盘接缝 `saveFile`、hex/图片键、正文搜索、按
`Content-Encoding` 解码、未知编码回退、首次加载失败恢复均无实现。）

## 1. Implementation

### `lib/page/proxy/proxy_capture_detail_page.dart`

- **按 `Content-Encoding` 解码展示**：新增纯函数 `_decodeContentEncoding`（`gzip` /
  `x-gzip` / `deflate` → 解压；`identity` / 空 → 原字节；未知 `br` / `zstd` 或
  解压失败 → **原字节回退，绝不抛**）。`_BodyBlock` 新增 `contentEncoding`（取自
  请求 / 响应头 `content-encoding`）。解码成功时显示 `解码后 N B · <encoding>`
  （`body_decoded_size_<req|resp>`），N = 解压后字节数。
- **二进制 hex 视图**：`_BodyBlock` 视图模式新增 `十六进制`（`body_hex_<id>`），
  内容为 `_toHexDump`（每行 16 字节，`offset  hex…  ascii`），键
  `body_hex_view_<id>`。
- **图片预览**：`contentType` 以 `image/` 开头且字节非空时渲染
  `Image.memory`（键 `body_image_<id>`），`errorBuilder` 降级为占位，坏图不崩。
- **正文搜索**：`TextField`（`body_search_<id>`）+ 命中计数 `命中 N 处` /
  `无匹配`（`body_search_hit_<id>`，`_countOccurrences` 大小写不敏感）。
- **存盘（byte-identical）**：新增可注入接缝
  `CaptureSaveFile saveFile`（生产默认 `FilePicker.platform.saveFile`）。Body 工具
  栏新增保存键 `body_save_<req|resp>`，写出**原始抓包字节**（`widget.bytes`，不做
  任何重编码），文件名 `capture_<recordId>_<req|resp>.<ext>`（`_extensionFor`）。
- **重发到请求调试**：新增 `CaptureDetailAction? onResendToDebug` 接缝 + 动作项
  `action_resend_debug`（`TablerIcons.send`）。
- **时间线瀑布**：`_TimelineSegment` 新增 `_TimelineWaterfall`（键
  `timeline_waterfall`），用 `startedAtMs / finishedAtMs / durationMs` 画占比条
  （`duration / span`，越界 clamp），附开始 / 耗时 / 结束标签；只用可用字段。
- 设计系统：全部 `Theme` 令牌 / `AppSpacing` / `AppTypography` / `AppRadius`；
  无硬编码颜色字号；无 `showDialog` / 手写 bottom sheet。

### `lib/page/proxy/proxy_requests_page.dart`

- **首次加载失败冻结修复（依赖 T22）**：T22 的 `_poll()` 成功后只回填数据、**从不
  清除 `_error`**；首屏 `_reload` 失败即 `_error != null`，`_buildContentSlivers`
  永久渲染「请求列表不可用」错误态，后续成功拉取也无从显示 → 列表冻结。修复为
  `_poll()` 成功时 `_error = null`。
- **重发接线**：`_openCaptureDetail` 透传 `onResendToDebug`；`_resendToRequestDebug`
  先经 `_captureActionBinder.saveToDebug`（复用抓包落库桥）保存，再 `appRouter.go
  (AppRoute.requestDebug)` 落到「请求调试」工作台默认「集合」分区（T7 路由入口）。

## 2. GREEN — T23 acceptance

`LD_LIBRARY_PATH=/tmp flutter test test/proxy_capture_detail_enhanced_test.dart`

```
00:00 +0: hex 视图与图片预览：渲染无异常
00:00 +1: 正文搜索命中：显示命中数量
00:01 +2: 按 Content-Encoding 解码：解码后大小正确
00:01 +3: 未知 content-encoding：回退原文，不崩
00:01 +4: 保存响应体：写入字节与原字节一致
00:01 +5: 首次加载失败后实时刷新恢复：列表不冻结
ProxyAppIdentityResolver: 非 Android 平台，跳过应用身份加载
00:01 +6: All tests passed!
```

## 3. Required regression suites (green)

`LD_LIBRARY_PATH=/tmp flutter test test/proxy_capture_detail_enhanced_test.dart
test/proxy_capture_detail_page_test.dart test/proxy_requests_pagination_test.dart`

```
...
00:05 +29: /home/.../proxy_capture_detail_page_test.dart: 对抗：删除失败 -> showError 且留在详情页不 pop
00:06 +30: All tests passed!
```

另跑 `proxy_requests_page_test.dart`（合并）：

```
... +53: All tests passed!
```

## 4. Static analysis

`dart analyze lib/page/proxy/proxy_capture_detail_page.dart
lib/page/proxy/proxy_requests_page.dart test/proxy_capture_detail_enhanced_test.dart`

```
No issues found!
```

`dart analyze lib/`：`729 issues found.`（与 T22 基线一致，均为既有 info）；
`dart analyze lib/ | grep -E "proxy_capture_detail_page|proxy_requests_page"` → **NONE**（改动文件无新增问题）。

## 5. Scope / guardrails

- 契约未改（未触碰 `rust/gstore_mod_proxy/*` 与 `ProxyContract.dart`）；不做 WS 改写。
- 无新依赖（复用既有 `file_picker`）；`pubspec.yaml` / 版本未改。
- 未改共享设计组件；无禁用弹层；危险删除仍走 `showConfirmSheet(isDangerous: true)`。
- 存盘写原始字节（byte-identical），不重编码；未知 `Content-Encoding` 回退原文不崩。
- `dist/`（未跟踪、既有）排除在暂存之外。
