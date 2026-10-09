# Task 21 — 实时连接页（`conn.list` / `conn.close` / `conn.close_all`）

Plan: `.omo/plans/net-req-debug-enhancement.md` todo 21
Commit message: `feat(proxy-ui): live connections page`

## 1. TDD — failing test first (RED)

Test written before any implementation: `test/proxy_connections_page_test.dart`
(missing `proxy_connections_facade.dart` + `proxy_connections_page.dart`).

Raw RED output (`LD_LIBRARY_PATH=/tmp flutter test test/proxy_connections_page_test.dart`):

```
  test/proxy_connections_page_test.dart:23:8: Error: Target of URI doesn't exist:
  'package:gstore/page/proxy/proxy_connections_facade.dart'.
  ...
  test/proxy_connections_page_test.dart:24:8: Error: Target of URI doesn't exist:
  'package:gstore/page/proxy/proxy_connections_page.dart'.
  ...
  test/proxy_connections_page_test.dart:93:41: Error: Type 'ProxyConnectionsFacade' not found.
    class _FakeConnectionsFacade implements ProxyConnectionsFacade {
  ...
  test/proxy_connections_page_test.dart:189:11: Error: Method not found: 'ProxyModuleConnectionsFacade'.
  test/proxy_connections_page_test.dart:262:9: Error: Method not found: 'ProxyConnectionsPage'.
  .
  00:00 +0 -1: Some tests failed.
  Failing tests:
    .../test/proxy_connections_page_test.dart: loading .../test/proxy_connections_page_test.dart
```

## 2. Implementation

- `lib/page/proxy/proxy_connections_facade.dart` (new): narrow
  `ProxyConnectionsFacade` (`connList` / `connClose` / `connCloseAll`) +
  production `ProxyModuleConnectionsFacade` — a **thin forwarder** over
  `ProxyModule.connList/connClose/connCloseAll`. No parsing/aggregation/
  persistence; the frozen `ProxyFacade` is untouched.
- `lib/page/proxy/proxy_connections_page.dart` (new): `ProxyConnectionsPage`
  (injectable `facade` + `events`). Lists connections; domain substring /
  outbound exact filters forwarded to `conn.list`; pagination via
  `offset = _connections.length` + `hasMore` → 「加载更多」; single disconnect
  (`AppDialogs.showConfirmSheet(isDangerous:true)` → `conn.close` → reload);
  disconnect-all (AppBar → `conn.close_all` → reload); empty state; explicit
  error state (module unavailable → title + message + 重试). Design system only:
  theme tokens, `AppLoading`, `ColoredAliIcon`, `AppDialogs` sheets — no
  hardcoded colors/sizes, no forbidden dialogs.
- `lib/page/proxy/proxy_home_page.dart`: added an `onOpenConnections` injection
  seam (production fallback opens `ProxyConnectionsPage`) and a quick-entry
  `ListTile` (`key: proxy-connections-tile`) showing the live count
  `'${_stats?.activeConns ?? 0} 个活动连接'`.

## 3. GREEN — T21 acceptance

`LD_LIBRARY_PATH=/tmp flutter test test/proxy_connections_page_test.dart`

```
00:00 +0: ProxyModuleConnectionsFacade 转发 conn.list/close/close_all 并按契约解码与透传请求字段
00:00 +1: ProxyModuleConnectionsFacade 缺字段 / 空响应不崩溃（解码为默认值）
00:00 +2: 列出活动连接：域名 / 出站 / 字节渲染
00:00 +3: 域名筛选转发到 conn.list 且只渲染返回结果
00:00 +4: 单条断开：确认后调用 conn.close 并刷新
00:01 +5: 全部断开：确认后调用 conn.close_all
00:01 +6: 空态渲染
00:01 +7: 错误态：模块不可用显式失败并可重试恢复
00:01 +8: All tests passed!
```

## 4. Required regression suites (green)

`LD_LIBRARY_PATH=/tmp flutter test test/proxy_connections_page_test.dart
test/proxy_requests_page_test.dart test/proxy_home_page_test.dart`

```
00:14 +105: All tests passed!
```

## 5. Static analysis

`LD_LIBRARY_PATH=/tmp dart analyze lib/page/proxy/proxy_connections_page.dart
lib/page/proxy/proxy_connections_facade.dart lib/page/proxy/proxy_home_page.dart
test/proxy_connections_page_test.dart`

```
Analyzing proxy_connections_page.dart, proxy_connections_facade.dart, proxy_home_page.dart, proxy_connections_page_test.dart...
No issues found!
```

## 6. Scope / guardrails

- Frozen contract untouched: only read-only consumption of existing `conn.*`
  methods; no `ProxyContract.dart` / Rust change.
- No new dependencies; no pubspec/version change.
- No shared design component modified; no new dialog/bottom-sheet.
- `dist/` (untracked, pre-existing) excluded from staging.
