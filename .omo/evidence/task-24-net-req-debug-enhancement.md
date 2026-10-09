# Task 24 — 订阅增强（编辑 / Clash 导出 / 排程 / 分享 + refresh_all skipped + 可刷新性）

Plan: `.omo/plans/net-req-debug-enhancement.md` todo 24
Commit message: `feat(proxy-ui): profile edit, clash export, schedule`
Prior commits preserved through `e2d90dd`

## 0. TDD — failing test first (RED)

先写 `test/proxy_profiles_enhanced_test.dart`（5 个用例：重命名 / 导出 / 排程 /
skipped / 不可刷新来源），再改生产代码。原始 RED
（`LD_LIBRARY_PATH=/tmp flutter test test/proxy_profiles_enhanced_test.dart`）：

```
00:00 +0: loading /home/hezhihu89/develop/flutter/project/GStore/test/proxy_profiles_enhanced_test.dart
test/proxy_profiles_enhanced_test.dart:288:47: Error: No named parameter with the name 'saveFile'.
      _host(ProxyProfilesPage(facade: facade, saveFile: save.call)),
                                              ^^^^^^^^
lib/page/proxy/proxy_profiles_page.dart:46:9: Context: Found this candidate, but the arguments don't match.
  const ProxyProfilesPage({
        ^^^^^^^^^^^^^^^^^^
00:00 +0 -1: loading /home/hezhihu89/develop/flutter/project/GStore/test/proxy_profiles_enhanced_test.dart [E]
  Failed to load ".../proxy_profiles_enhanced_test.dart":
  Compilation failed for testPath=.../proxy_profiles_enhanced_test.dart: ... No named parameter with the name 'saveFile'.
00:00 +0 -1: Some tests failed.

Failing tests:
  /home/hezhihu89/develop/flutter/project/GStore/test/proxy_profiles_enhanced_test.dart: loading ... [E]
```

（RED 为「新能力尚不存在」：`profile.update` / `profile.export_clash` /
`profile.set_schedule` 门面方法、导出另存接缝 `saveFile`、卡片「更多」菜单、
`refresh_all.skipped[]` 展示与强制更新、不可刷新来源隐藏刷新按钮均无实现。）

一个中间 RED 也确认了 skipped 弹层与无限动画的交互（`pumpAndSettle` 因 AppLoading
不收敛而超时），随后改用固定帧推进 `_tick` 修正测试驱动方式：

```
00:03 +3 -1: 全部更新：展示 skipped 原因并可强制更新 [E]
The following assertion was thrown running a test:
pumpAndSettle timed out
```

## 1. Implementation

### `lib/page/proxy/proxy_profiles_facade.dart`（窄接口，纯透传，不改冻结契约）

新增 3 个方法并接入生产适配器 `ProxyModuleProfilesFacade`：

- `profileUpdate(Map<String, dynamic> payload)` → `ProxyModule.profileUpdate`
- `profileExportClash(ProfileExportRequest request)` → `ProxyModule.profileExportClash`
- `profileSetSchedule(String id, int intervalMs)` → `ProxyModule.profileSetSchedule`

只做参数透传，无解析 / 改写；订阅存储格式未触碰。

### `lib/page/proxy/proxy_profiles_page.dart`

- **重命名（`profile.update`）**：卡片「更多」菜单 →「重命名」→ `_RenameSheet`
  表单（预填当前名）→ `profileUpdate({'id', 'name'})` → `_load()` 刷新列表。
- **Clash 导出（`profile.export_clash`）**：「更多」→「导出 Clash」→
  `profileExportClash(ProfileExportRequest(id))` → 把返回的 `GeneratedConfig.config`
  UTF-8 编码后经 `ProfileSaveFile` 另存为 `<name>.yaml`；取消静默、失败提示。
  新增测试接缝 `ProfileSaveFile`（默认 `FilePicker.platform.saveFile`）。
- **排程（`profile.set_schedule`）**：「更多」→「自动更新间隔」→ 统一选择弹层
  （关闭 / 1 / 6 / 12 / 24 小时）→ `profileSetSchedule(id, intervalMs)` → `_load()`，
  由 `ProfileSummary.refresh.intervalMs` 回读展示 `自动更新 N 小时`。
- **`refresh_all` skipped + force**：`_refreshAll()` 收到 `result.skipped[]` 非空时，
  用 `AppDialogs.showContentSheet` 列出每个来源名称 + 中文原因
  （not_refreshable / backoff / interval / limit / error → 中文标签），
  提供「强制更新」按钮 → 再次 `profileRefreshAll(force: true)`；`_announceRefreshAll`
  把跳过数计入汇总文案。
- **可刷新性**：`_isRefreshable()`（`sourceOrigin` 非 `text`/`link` 且 `sourceUrl`
  非空）为假时**不渲染**单个「更新」按钮（AppBar 的「全部更新」保留，由 skipped
  展示不可刷新原因）。
- 设计系统：全部走 `AppDialogs` / `AppSheet` / `AppSheetScaffold`，图标 `TablerIcons`
  与 `ColoredAliIcon`，间距 / 圆角 / 字号用 `AppSpacing` / `AppRadius` /
  `AppTypography` / 主题令牌；无硬编码颜色、无 `showDialog` / 手写 bottom sheet。

### `test/proxy_profiles_page_test.dart`

既有假门面 `_FakeProfilesFacade` 补上 3 个新接口方法（内存改名 / 返回空配置 /
返回空 StoredProfile），保持既有 14 个用例全绿。

## 2. Verification (raw)

### `dart analyze`（改动文件）

```
$ dart analyze lib/page/proxy/proxy_profiles_page.dart lib/page/proxy/proxy_profiles_facade.dart test/proxy_profiles_enhanced_test.dart test/proxy_profiles_page_test.dart
Analyzing proxy_profiles_page.dart, proxy_profiles_facade.dart, proxy_profiles_enhanced_test.dart, proxy_profiles_page_test.dart...
No issues found!
```

全量 `dart analyze lib/` 为 729 条既有 info（settings/update/webdav 等无关文件），
其中 **不含任何 `proxy_profiles` 文件**：

```
$ dart analyze lib/ 2>&1 | grep -E "proxy_profiles"
NO ISSUES in proxy_profiles files
```

### 目标测试（RED → GREEN）

```
$ LD_LIBRARY_PATH=/tmp flutter test test/proxy_profiles_enhanced_test.dart
00:00 +0: loading .../proxy_profiles_enhanced_test.dart
00:00 +0: 重命名：编辑名称后调用 profile.update 并刷新列表
00:01 +1: 导出：Clash 配置含节点与规则并另存
00:01 +2: 排程：设置 6 小时间隔后回读一致
00:01 +3: 全部更新：展示 skipped 原因并可强制更新
00:01 +4: 不可刷新来源：不显示单个刷新按钮
00:01 +5: All tests passed!
```

### 既有测试（不回归）

```
$ LD_LIBRARY_PATH=/tmp flutter test test/proxy_profiles_page_test.dart
00:00 +0: 列表：展示名称 / 来源 / 节点数 / 流量与到期 userinfo
...
00:02 +14: All tests passed!
```

### 合并运行（两文件）

```
$ LD_LIBRARY_PATH=/tmp flutter test test/proxy_profiles_enhanced_test.dart test/proxy_profiles_page_test.dart
...
00:02 +19: All tests passed!
```

## 3. Acceptance mapping

| 计划验收项 | 测试用例 |
| --- | --- |
| 改名后列表刷新 | 「重命名：编辑名称后调用 profile.update 并刷新列表」（断言 `updateCount==1`、payload `id/name`、列表显示新名） |
| 导出含节点/规则 | 「导出：Clash 配置含节点与规则并另存」（解码另存字节含 `香港 01`、`DOMAIN-SUFFIX,example.com,PROXY`、`MATCH,DIRECT`） |
| 设置间隔回读一致 | 「排程：设置 6 小时间隔后回读一致」（`lastScheduleInterval==21600000`，列表显示 `自动更新 6 小时`） |
| skipped 展示 | 「全部更新：展示 skipped 原因并可强制更新」（含 `来源不可刷新` / `失败退避中`，点强制后 `lastForceAll==true`、`refreshAllCount==2`） |
| 不可刷新源无刷新按钮 | 「不可刷新来源：不显示单个刷新按钮」（仅 1 个「更新」按钮，文本源无） |

## 4. Guardrails honored

- 未改订阅存储格式（仅 Dart 展示层 + 薄门面透传）。
- 未改冻结契约 / Rust / `ProxyContract.dart` / `ProxyModule.dart`。
- 无新依赖；未动 `pubspec.yaml` / 版本号 / 共享组件 / 无关页面。
- 无 `showDialog` / 手写 `showModalBottomSheet` / `Get.defaultDialog`；无硬编码颜色。
