# Task 31 — app-identity 性能 + geo 校验安全 + 首页事件处理

Plan: `.omo/plans/net-req-debug-enhancement.md` (Todo 31)
Commit scope: `fix(proxy): app-identity perf, geo integrity, home events`
Date: 2026-10-09

## Scope delivered

1. **App icons 按需 / 批量解析**：`ProxyAppIdentityResolver` 拆分为「元数据加载」与
   「图标落盘」两阶段。`ensureLoaded(resolveIcons: false)` 只加载应用名（零写盘）；
   `resolveIcons(...)` / `resolveIcon(...)` 按需、按批（默认 8/批）并发落盘，
   **不再在加载循环里逐个同步写盘**。
2. **临时缓存清理 + 重扫**：新增 `cleanupIconCache()`（删除 `proxy_app_icons` 下孤儿
   `.png`，保留当前包集合）与 `rescan()`（重扫 + 清理）；生产默认 saver 下加载后自动
   清理遗留图标。
3. **Geo 校验安全**：`RhttpAdapter` 现在真正遵守 `allowBadCertificate`（
   `verifyCertificates: !allowBadCertificate`，此前参数被忽略、恒为 `false`）；
   `DioProxyGeoChecksumClient` 默认 Dio 改用 `allowBadCertificate: false` —— 经 TLS
   正常校验证书后再从 `.sha256sum`（校验清单）取哈希钉住下载。**校验客户端不再有
   `allowBadCertificate: true`**。
4. **首页事件反馈**：`_onEvent` 消费 `proxy.subscription.updated/progress/failed/
   added/removed` 与 `proxy.config.applied`，以主题令牌化的非阻塞横幅反馈
   （`proxy-subscription-notice` / `proxy-config-applied-notice`）；订阅增删触发
   订阅列表重解析。原有 `proxy.state/mode/stats/node.delay/conn/dns/tun.released/
   request` 处理保持不变（隧道事件正确性不降低）。
5. **geo waitReady 随页面销毁取消**：新增 `ProxyGeoProvisioner.cancelWaitReady()`；
   `waitReady` 在每个检查点检查取消令牌；`ProxyHomePage.dispose()` 调用
   `_geoProvisioner?.cancelWaitReady()`，销毁后不再轮询 `rulesGet`。

## Failing-first (RED) proof

Command (before implementation):

```
LD_LIBRARY_PATH=/tmp flutter test test/proxy_app_identity_geo_test.dart test/proxy_home_events_test.dart
```

Raw output excerpt (`/tmp/opencode/t31/red.txt`, exit=1):

```
test/proxy_app_identity_geo_test.dart:148:9: Error: No named parameter with the name 'iconCacheCleaner'.
test/proxy_app_identity_geo_test.dart:186:49: Error: Member not found: 'DioProxyGeoChecksumClient.buildDefaultDio'.
test/proxy_app_identity_geo_test.dart:97:35: Error: No named parameter with the name 'resolveIcons'.
test/proxy_app_identity_geo_test.dart:104:22: Error: The method 'resolveIcons' isn't defined for the type 'ProxyAppIdentityResolver'.
test/proxy_app_identity_geo_test.dart:190:35: Error: The getter 'allowBadCertificate' isn't defined for the type 'RhttpAdapter'.
test/proxy_app_identity_geo_test.dart:231:19: Error: The method 'cancelWaitReady' isn't defined for the type 'ProxyGeoProvisioner'.
  Failed to load ".../test/proxy_app_identity_geo_test.dart"
...
00:02 +0 -6: Some tests failed.
Failing tests:
  test/proxy_app_identity_geo_test.dart: loading ... (compile failure)
  test/proxy_home_events_test.dart: 订阅更新事件触发 UI 反馈（节点数）
  test/proxy_home_events_test.dart: 订阅失败事件触发错误反馈
  test/proxy_home_events_test.dart: 订阅新增事件触发 UI 反馈
  test/proxy_home_events_test.dart: 配置已应用事件触发 UI 反馈
  test/proxy_home_events_test.dart: 页面销毁取消 geo waitReady 轮询
```

## GREEN proof

Command:

```
LD_LIBRARY_PATH=/tmp flutter test test/proxy_app_identity_geo_test.dart test/proxy_home_events_test.dart
```

Raw output (`/tmp/opencode/t31/green.txt` tail):

```
00:00 +7: ... test/proxy_home_events_test.dart: 订阅更新事件触发 UI 反馈（节点数）
00:00 +8: ... test/proxy_home_events_test.dart: 订阅失败事件触发错误反馈
00:00 +9: ... test/proxy_home_events_test.dart: 订阅新增事件触发 UI 反馈
00:01 +10: ... test/proxy_home_events_test.dart: 配置已应用事件触发 UI 反馈
00:01 +11: ... test/proxy_home_events_test.dart: 页面销毁取消 geo waitReady 轮询
00:01 +12: All tests passed!
```

Regression suite (new + existing), same run:

```
LD_LIBRARY_PATH=/tmp flutter test \
  test/proxy_app_identity_geo_test.dart test/proxy_home_events_test.dart \
  test/proxy_app_identity_test.dart test/proxy_home_page_test.dart \
  test/proxy_geo_provisioner_test.dart test/proxy_geo_manifest_test.dart
→ 00:07 +104: All tests passed!
```

Additional consumer regression:

```
LD_LIBRARY_PATH=/tmp flutter test test/app_identity_test.dart test/proxy_requests_page_test.dart
→ +36: All tests passed!
```

## Static analysis

```
dart analyze lib/page/proxy/proxy_app_identity.dart \
  lib/page/proxy/proxy_geo_provisioner.dart \
  lib/page/proxy/proxy_home_page.dart lib/http/rhttp_adapter.dart
→ No issues found!
```

Full `dart analyze lib/` filtered for changed files → `NO_ISSUES_IN_CHANGED_FILES`
(repo has 729 pre-existing info-level lints elsewhere; none in changed files).

## Acceptance mapping

| Acceptance criterion | Test |
| --- | --- |
| icons are NOT written per-item synchronously (batched/on-demand) | `ensureLoaded(resolveIcons:false) 不写盘；resolveIcons 按需解析` + `ensureLoaded 默认批量并发解析（非逐个同步写盘）` |
| checksum client enables certificate validation (bad-cert NOT allowed) | `DioProxyGeoChecksumClient 默认 Dio 启用证书校验（不允许坏证书）` |
| a subscription event triggers a UI update | `订阅更新事件触发 UI 反馈（节点数）` (+ failed/added) |
| after dispose, geo polling stops | `waitReady 取消 取消后停止轮询（不再调用 rulesGet）` + `页面销毁取消 geo waitReady 轮询` |
| geo checksum failure fails explicitly | `校验和全部不可用 → kickoff 显式失败，不 reload` |

## Guardrails respected

- 不改冻结契约 / Rust；无新依赖；无 `pubspec.yaml` / 版本改动。
- 设计系统：横幅颜色 / 字号全部走 `Theme.of(context).colorScheme` / `textTheme`
  与 `AppSpacing` / `AppRadius` / `AppTypography`；无硬编码颜色、无禁用弹层。
- 隧道事件处理未降低正确性（既有 `proxy_home_page_test.dart` 全绿）。
