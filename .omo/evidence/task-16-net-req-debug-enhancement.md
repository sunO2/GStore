# Task 16 — 请求调试导入 / 导出（HAR / Postman / OpenAPI / 原始 HTTP / 环境 / 规则）

计划：`.omo/plans/net-req-debug-enhancement.md` todo 16（`[pure-Dart-now]`，依赖 1,2,3,4,11,12）。

## 交付物

新增纯逻辑包 `lib/core/request_debug/import_export/`（**零 IO / 零 UI / 零新依赖**）：

| 文件 | 内容 |
| --- | --- |
| `import_export_types.dart` | `DebugTransferFormat` 枚举、`DebugTransferError(Kind)`、`DebugTransferResult<T>`（成功 / 失败互斥，失败结构化，绝不抛） |
| `codec_utils.dart` | 跨格式纯辅助：URL 合并 / 拆分、MIME⇄bodyKind、头查找、form 解析 |
| `har_codec.dart` | HAR 1.2 `encodeHar` / `decodeHar`（标准节点 + `_gstore*` 无损扩展；外部 HAR 可读） |
| `postman_codec.dart` | Postman v2.1 `encodePostman` / `decodePostman`（嵌套 `item` + `x-gstore-request` 无损扩展；外部可读） |
| `openapi_codec.dart` | OpenAPI 3 `encodeOpenApi` / `decodeOpenApi`（**仅 JSON**，`x-gstore-debug` 无损扩展 + `servers`/`paths` 重建） |
| `raw_http_codec.dart` | 原始 HTTP `encodeRawHttp` / `decodeRawHttp`（`###` 分隔多请求） |
| `debug_import_export.dart` | 统一门面 `DebugImportExport`（集合编解码 / `detectFormat` / 环境与规则 JSON）+ `remapImportedCollections` |
| `import_export.dart` | 包统一出口 |

页面层接线（沿用既有 FilePicker 方式）：

- `lib/page/request_debug/import_export_actions.dart`：文件选择 / 保存接缝（默认 `FilePicker.platform.pickFiles` / `saveFile`，测试可注入）+ 导入 / 导出动作（提示走 `AppDialogs`）。
- `collection_section.dart`：`request-debug-collection-transfer` 菜单（导入集合文件 + 导出 HAR/Postman/OpenAPI/原始 HTTP）。
- `environment_section.dart`：`request-debug-environment-export`（导出环境 JSON）。
- `rules_section.dart`：`request-debug-rules-export`（导出规则 JSON）。

测试：`test/request_debug_import_export_test.dart`（18 用例）。

## 依赖决策（零新增）

- **未新增任何依赖**，`pubspec.yaml` 未改动（版本号亦未改）。
- **OpenAPI 仅支持 JSON 输入**，刻意不引入 YAML 解析库：符合计划“prefer NOT adding one if avoidable（可仅支持 JSON OpenAPI 输入）”。需要 YAML 的用户可自行转换为 JSON 后导入。
- 编解码只用 `dart:convert` + 既有纯模型 `debug_models.dart`。
- 无 OpenAPI Java CLI、无大型依赖。

## TDD 证据

- RED（实现前）：`flutter test test/request_debug_import_export_test.dart` 编译失败（`Target of URI doesn't exist: .../import_export/import_export.dart`），退出码 1 —— 原始输出见 `task-16-red.txt`。
- GREEN：18/18 通过 —— 原始输出见 `task-16-green.txt`。
- 回归（要求的 5 个文件）：117/117 通过 —— 原始输出见 `task-16-regression.txt`。
- 额外全量 request_debug 套件：266/266 通过（含 `page_test` / `url_params_sync` / `kv_editor` / `store*` 等）。
- 静态门：`dart analyze lib/core/request_debug/import_export/ lib/page/request_debug/` → **No issues found!**（`task-16-analyze.txt`）；全量 `dart analyze lib/` 中**改动文件 0 条**（既有 729 条均为未触碰文件的历史 info/warning）。

## 验收对照

| 验收项 | 结果 |
| --- | --- |
| 每格式 round-trip（encode→decode→等价） | HAR / Postman / OpenAPI 集合树等价；原始 HTTP 请求等价 ✅ |
| 非法 / 截断文件返回**结构化错误**（不崩） | 空 / 截断 JSON / 非法 JSON / 无请求行 → `DebugTransferResult.failure`，无异常 ✅ |
| 导出样例含关键字段（method/url/headers/body） | HAR / Postman / OpenAPI / 原始 HTTP 分别断言 ✅ |
| 环境与规则导出 JSON | `encodeEnvironmentsJson` / `encodeRulesJson` round-trip ✅ |
| 文件选择沿用 FilePicker | `defaultDebugPickFile` / `defaultDebugSaveFile` 走 `FilePicker.platform` ✅ |
| 无新依赖 / 无 YAML / 无 Java CLI | ✅ |
| 设计系统合规 | 提示走 `AppDialogs`，图标 `Icon(TablerIcons.*)`，无硬编码颜色 ✅ |

## 未做 / 边界

- OpenAPI **不含 YAML**（见上）。
- 环境 / 规则仅导出 JSON（按计划），未提供导入 UI（纯函数 `decodeEnvironmentsJson` / `decodeRulesJson` 已就绪）。
- 原始 HTTP 的 bodyKind 依赖 Content-Type 或 JSON 启发式；无扩展时禁用头不保留（格式本身无此概念）。

## Commit

`feat(request-debug): import/export HAR, Postman, OpenAPI`
