# Task 26 — 统计 / DNS 增强（下钻 / 排序映射 / 分页 / 复制 / 导出）

- Plan: `.omo/plans/net-req-debug-enhancement.md` — Todo 26 `[pure-Dart-now]`
- Date: 2026-10-09
- Writer: implementation worker (sole writer for this todo)
- Prior commits preserved through `9477246`
- Contract: **未改** `stats.domain.get`（分页沿用 `limit`/`range`，排序只下发契约键），未改 Rust / `API.md` / `ProxyContract.dart`

## 交付内容

| 能力 | 入口/符号 | 说明 |
| --- | --- | --- |
| 统计域名下钻 | `ProxyStatsPage.onDrilldown` → `ProxyRequestsPage(initialDomain:)` | 点击域名卡片推入按该域名筛选的请求列表；`initialDomain` 预填搜索框并本地过滤（`_searchQuery`） |
| 排序列 wire 映射修复 | `proxy_stats_helpers.dart: proxyStatsServerSortFor` | 7 列 → 契约键唯一映射：`bytes/connections/lastSeen/domain` 原生键；上传/下载/策略**不再复用 `bytes`**，返回 `null`（后端默认），本地比较器决定顺序 |
| 复制域名 / 出站 | `stat_copy_domain_<domain>` / `stat_copy_outbound_<domain>` | `Clipboard.setData` + `AppDialogs.showSuccess` |
| 导出 CSV | `ProxyStatsPage.saveFile` 接缝；`buildStatsCsv` | appbar `stats_export`；RFC4180 转义；UTF-8；FilePicker 另存；用户取消静默 |
| DNS 去 20 条硬截断 | `dns_queries_more` / `dns_mappings_more`；`dns_query_count` / `dns_mapping_count` | 初始 20 条，按块累加展开；显示「共 N 条」总数 |
| DNS 应答记录 | `dns_query_answers_<i>` | 渲染 `DnsQueryRecord.answers` |
| DNS 复制 | `dns_copy_query_<i>` / `dns_copy_mapping_<i>` | 复制查询域名 / `domain ip` 映射 |

## 变更文件

- `lib/page/proxy/proxy_stats_helpers.dart`（新增：`ProxyStatSort` / `proxyStatsServerSortFor` / `kStatsServerSortKeys` / `buildStatsCsv`）
- `lib/page/proxy/proxy_stats_page.dart`（下钻 / 复制 / CSV 导出 / 排序映射接线）
- `lib/page/proxy/proxy_requests_page.dart`（新增 `initialDomain` 下钻筛选种子）
- `lib/page/proxy/proxy_dns_page.dart`（去截断 + 展开/总数 + 应答 + 复制）
- `test/proxy_stats_dns_enhanced_test.dart`（新增：10 个 TDD 用例）

## TDD：RED（先写测试，失败）

命令：`LD_LIBRARY_PATH=/tmp flutter test test/proxy_stats_dns_enhanced_test.dart`

结果：`exit=1`，测试文件**无法加载**（引用尚不存在的符号），即失败先行：

```
test/proxy_stats_dns_enhanced_test.dart:29:8: Error: Target of URI doesn't exist:
  'package:gstore/page/proxy/proxy_stats_helpers.dart'.
test/proxy_stats_dns_enhanced_test.dart:254:14: Error: The function
  'proxyStatsServerSortFor' isn't defined.
test/proxy_stats_dns_enhanced_test.dart:323:9: Error: No named parameter with the
  name 'onDrilldown'.  ... Found this candidate: const ProxyStatsPage({super.key, this.facade});
test/proxy_stats_dns_enhanced_test.dart:346:9: Error: No named parameter with the
  name 'initialDomain'. ... const ProxyRequestsPage({ ... });
test/proxy_stats_dns_enhanced_test.dart:383:9: Error: No named parameter with the
  name 'saveFile'. ... const ProxyStatsPage({super.key, this.facade});
00:00 +0 -1: Some tests failed.
Failing tests:
  test/proxy_stats_dns_enhanced_test.dart: loading test/proxy_stats_dns_enhanced_test.dart
```

行为缺口（RED 覆盖，实现后转 GREEN）：
1. 排序列：切换「上传/下载/策略」时当前实现下发 `bytes`（误导性复用），期望 `null`。
2. 下钻：域名卡片无点击行为。
3. 复制/导出：统计卡片无复制按钮、appbar 无导出入口。
4. DNS：`.take(20)` 硬截断，无展开/总数、无应答、无复制。

## TDD：GREEN（实现后，全绿）

命令（任务要求的全套）：

```
LD_LIBRARY_PATH=/tmp flutter test test/proxy_stats_dns_enhanced_test.dart
```

原始输出（尾部）：

```
00:00 +0: loading test/proxy_stats_dns_enhanced_test.dart
00:00 +0: 统计：排序列 → 服务端 sort 键映射 纯映射：7 列逐一正确，无偏置（upload/download/outbound 无原生键）
00:00 +1: 统计：排序列 → 服务端 sort 键映射 widget：切换每列后下发的 sort 键正确
00:01 +2: 统计：下钻 / 复制 / 导出 下钻：点击域名卡片携带该域名筛选
00:01 +3: 统计：下钻 / 复制 / 导出 下钻：请求列表按 initialDomain 本地过滤
00:01 +4: 统计：下钻 / 复制 / 导出 复制：复制域名与出站到剪贴板
00:01 +5: 统计：下钻 / 复制 / 导出 导出：CSV 含表头与数据行并经另存接缝落盘
00:01 +6: DNS：去截断 / 应答 / 复制 近期查询与映射可展开超过 20 条并显示总数
00:02 +7: DNS：去截断 / 应答 / 复制 展示应答记录
00:02 +8: DNS：去截断 / 应答 / 复制 复制：查询域名与映射
00:02 +9: 统计：空态 空统计渲染显式空态而非空白
00:02 +10: All tests passed!
```

既有回归（统计 / DNS / 请求列表，全绿）：

```
LD_LIBRARY_PATH=/tmp flutter test \
  test/proxy_diagnostics_pages_test.dart \
  test/proxy_requests_page_test.dart \
  test/proxy_requests_pagination_test.dart \
  test/proxy_requests_facade_test.dart
=> 00:05 +48: All tests passed!
```

## 静态分析

```
dart analyze lib/page/proxy/proxy_stats_page.dart \
  lib/page/proxy/proxy_stats_helpers.dart \
  lib/page/proxy/proxy_dns_page.dart \
  lib/page/proxy/proxy_requests_page.dart
=> No issues found!
```

`dart analyze lib/`（全库 729 条为既有 info，`grep` 命中 0 条落在本次改动文件）。

## 排序映射修复说明（无偏置）

契约 `stats.domain.get.sort ∈ {bytes, connections, lastSeen, domain}`（`API.md §2.9`，未改）。

| 列 | 旧行为 | 新行为 |
| --- | --- | --- |
| 流量 bytes | `bytes` | `bytes` |
| 连接数 connections | `connections` | `connections` |
| 上传 upload | `bytes`（复用） | `null`（本地排序） |
| 下载 download | `bytes`（复用） | `null`（本地排序） |
| 最近 lastSeen | `lastSeen` | `lastSeen` |
| 策略 outbound | `bytes`（复用） | `null`（本地排序） |
| 域名 domain | `domain` | `domain` |

纯函数按枚举索引逐一断言（`ProxyStatSort.values[0..6]`），并断言任何非空键 ∈ `kStatsServerSortKeys`，防列顺序偏移回归。

## 设计系统合规

- 颜色/字号全部 `Theme.of(context).colorScheme` / `textTheme` / `AppTypography` / `AppSpacing`，无硬编码。
- 提示经 `AppDialogs.showSuccess/showError`；loading 用 `AppLoading`；未新增 `showDialog` / 手写 `showModalBottomSheet` / `Get.defaultDialog`。
- 未改共享组件（`AppSegmentedButton`/`AppTextField`）、`pubspec.yaml`、版本号；未改 Rust / 契约 / `API.md`。
