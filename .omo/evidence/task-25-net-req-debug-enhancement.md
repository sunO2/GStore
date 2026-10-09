# Task 25 — 节点增强（搜索/收藏/详情/复制 + `_nodesByName` 重名修复 + `targets` 文档对齐）

- Plan: `.omo/plans/net-req-debug-enhancement.md` — Todo 25 `[contract-gated]`（本 todo 契约工作 **DOC-ONLY**，不改 dispatch）
- Date: 2026-10-09
- Writer: implementation worker (sole writer for this todo)
- Prior commits preserved through `432a672`.

## 交付内容

| 能力 | 入口/符号 | 说明 |
| --- | --- | --- |
| 节点搜索/筛选 | `ProxyNodesPage._buildSearchBar`（`proxy_nodes_search` / `proxy_nodes_search_clear`）| 按 名称 / 服务器 / 类型 / 端口 过滤；分组模式按分组名或成员节点命中过滤 |
| 收藏置顶 | `proxy_node_favorites_store.dart`；`_toggleFavorite`；`proxy_nodes_node_favorite` / `proxy_nodes_favorite_<name>` | 收藏键 `分组\u0000节点名`（同名不跨组串收藏）；收藏节点在节点宫格与分组弹层内均置顶 |
| 节点详情（只读契约字段） | `_NodeDetailView`（`proxy_nodes_detail`）；动作 `proxy_nodes_node_detail` | 展示 type/server/port/cipher/network/tls/sni/flow/security/alterId/fingerprint/alpn/obfs；凭据（password/uuid/obfsPassword）仅显示「已设置」，**不回显明文**；**无编辑** |
| 复制节点地址 | `_copyNodeAddress`（`proxy_nodes_node_copy`）| 复制 `server:port`（port=0 时仅 server），成功经 `AppDialogs.showSuccess` |
| `_nodesByName` 重名修复 | `_nodes` + `_resolveMemberNode(group, member)` | 节点存储改为保留重复名的 `List<ProxyNode>`；按 `ProxyNode.groups` 归属逐分组解析，**同名不同服务器不跨组串用** |
| `targets` 文档对齐 | `rust/gstore_mod_proxy/API.md §2.6` | 表格与散文补 `node.delay_test` 的 `targets?: [string]` 与选择器优先级；**纯文档**，未改 Rust/dispatch |

## 变更文件

- `lib/page/proxy/proxy_nodes_page.dart`（搜索/收藏/详情/复制 + 重名修复）
- `lib/page/proxy/proxy_node_favorites_store.dart`（新增：收藏持久化接缝）
- `test/proxy_nodes_enhanced_test.dart`（新增：5 个 TDD 用例）
- `test/proxy_nodes_page_test.dart`（更新：`搜索已移除` → `搜索：分组模式按分组名过滤`）
- `rust/gstore_mod_proxy/API.md`（§2.6 `targets`，DOC-ONLY）

## TDD：RED（先写测试，失败）

命令：`LD_LIBRARY_PATH=/tmp flutter test test/proxy_nodes_enhanced_test.dart`

结果：`exit=1`，5/5 失败（关键：重名节点在弹层里串用、搜索/收藏/复制/详情入口均不存在）。

```
00:00 +0 -1: 搜索：按名称/端点过滤，清空恢复（nodes 模式） [E]
00:01 +0 -2: 收藏：收藏节点置顶（nodes 模式） [E]
00:01 +0 -3: 重名节点：各分组解析各自节点（不串用）且独立选择 [E]
00:01 +0 -4: 复制：复制节点地址写入剪贴板 [E]
00:01 +0 -5: 详情：展示契约已有字段（类型/服务器/端口/加密） [E]
00:01 +0 -5: Some tests failed.
Failing tests:
  test/proxy_nodes_enhanced_test.dart: 搜索：按名称/端点过滤，清空恢复（nodes 模式）
  test/proxy_nodes_enhanced_test.dart: 收藏：收藏节点置顶（nodes 模式）
  test/proxy_nodes_enhanced_test.dart: 重名节点：各分组解析各自节点（不串用）且独立选择
  test/proxy_nodes_enhanced_test.dart: 复制：复制节点地址写入剪贴板
  test/proxy_nodes_enhanced_test.dart: 详情：展示契约已有字段（类型/服务器/端口/加密）
```

重名 RED 细节（实现前 `_nodesByName` 以名字为键，后者覆盖前者）：PROXY 分组弹层里的 `X`
显示的是 AUTO 的 `10.0.0.2:8443 · vmess`，而非 PROXY 自己的 `10.0.0.1:443 · ss`。

## TDD：GREEN（实现后，全绿）

命令（任务要求的全套）：

```
LD_LIBRARY_PATH=/tmp flutter test \
  test/proxy_nodes_enhanced_test.dart \
  test/proxy_contract_test.dart \
  test/proxy_nodes_page_test.dart
```

结果：`exit=0`，**68 tests passed**。

```
00:04 +68: All tests passed!
```

- 新增 `test/proxy_nodes_enhanced_test.dart`：5/5 绿（搜索、收藏置顶、重名独立、复制、详情）。
- 既有 `test/proxy_contract_test.dart`：绿（`API.md §2.6` 加字段不改变方法集，机器校验通过）。
- 既有 `test/proxy_nodes_page_test.dart`：绿（唯一改动为「搜索已移除」旧断言 → 新搜索断言）。
- 关联回归 `test/proxy_home_page_test.dart`：`68 tests passed`。

## 静态门

```
dart analyze lib/page/proxy/proxy_nodes_page.dart lib/page/proxy/proxy_node_favorites_store.dart
→ No issues found!

dart analyze lib/ | grep proxy_nodes_page.dart|proxy_node_favorites_store.dart
→ （无输出）NO ISSUES in changed lib files
```

## 设计系统合规

- 弹层一律 `AppSheet.showCustom` + `AppSheetScaffold`（无 `showDialog` / 手写 bottom sheet / `Get.defaultDialog`）。
- 颜色/字号全部取自 `Theme.of(context).colorScheme` / `textTheme`；图标为 TablerIcons（单色 `Icon`）。
- 搜索框复用与 `proxy_requests_page` 一致的 `TextField` 主题风格；loading 仍为 `AppLoading`。
- 无新依赖；未动 `pubspec.yaml` 版本；未改共享组件；未改 Rust/dispatch。

## 范围守卫（MUST NOT）

- **未加节点编辑**：详情为只读展示。
- **未改 dispatch/Rust 行为**：`API.md §2.6` 为纯文档对齐（`targets` 在 `nodes.rs:105,321` 已实现，无需 Rust 改动；若需改 Rust 归 C5）。
- 未新增依赖 / 未提交构建产物 / 未 `git add -A`。

## 证据原始文件

- RED：`/tmp/t25_red.txt`
- GREEN：`/tmp/t25_green.txt`
