# Task 14 — 二进制 / 截断 / 改写头卫生 — Evidence

Plan: `.omo/plans/net-req-debug-enhancement.md` todo 14
Commit: `fix(request-debug): correct truncation, binary copy, rewrite headers`

## What changed

| File | Change |
| --- | --- |
| `lib/core/request_debug/debug_response.dart` | `DebugResponse.truncated` + `sizeBytes` 改为优先取 `Content-Length` 真实值；`fromStreamed(truncated:)`；`rewriteStrippedResponseHeaders` + `rewriteRuleHeaders()`（剥离 hop-by-hop / content-encoding / content-length / transfer-encoding，含 `Connection` 列出的自定义 token）；快照还原传递 `truncated` |
| `lib/core/request_debug/debug_sender.dart` | `_readBounded` 返回 `_BoundedBody(bytes, truncated)`：只有确实还有未读数据才标记截断；透传给 `fromStreamed` |
| `lib/page/request_debug/response_viewer.dart` | 头部「已截断」徽标（`response-truncated`）；二进制复制改为 base64 原始字节；二进制卡片 `Material`+`InkWell` 真正可点（`onCopy` 贯穿行内/全屏）；`save-as-rewrite` 用 `rewriteRuleHeaders()`；错误/取消响应禁用保存 |
| `test/request_debug_response_test.dart` | 新增截断/真实大小、二进制 base64 复制+可点、改写头剥离、错误禁存、大响应分块用例 |

不改变小响应文本展示（`_displayResponseBodyText` 未动；`response-size` 小响应文案不变）。

## Failing-first (RED)

Command:
```
LD_LIBRARY_PATH=/tmp flutter test test/request_debug_response_test.dart
```
Result (before implementation):
```
test/request_debug_response_test.dart:54:7: Error: No named parameter with the name 'truncated'.
test/request_debug_response_test.dart:976:23: Error: The getter 'truncated' isn't defined for the type 'DebugResponse'.
test/request_debug_response_test.dart:1049:32: Error: The method 'rewriteRuleHeaders' isn't defined for the type 'DebugResponse'.
00:00 +0 -1: loading .../request_debug_response_test.dart [E]
  Failed to load ...: Compilation failed
00:00 +0 -1: Some tests failed.
```

## GREEN

```
LD_LIBRARY_PATH=/tmp flutter test test/request_debug_response_test.dart
...
00:05 +41: All tests passed!
```

```
LD_LIBRARY_PATH=/tmp flutter test test/request_debug_sender_test.dart \
  test/request_debug_capture_mapping_test.dart test/request_debug_editor_test.dart
...
00:06 +56: All tests passed!
```

Adjacent suites (impacted by `fromStreamed` / snapshot restore):
```
LD_LIBRARY_PATH=/tmp flutter test test/request_debug_history_response_test.dart \
  test/request_debug_facade_test.dart
00:01 +17: All tests passed!
```

Static gate:
```
dart analyze lib/
729 issues found.   # all pre-existing (info)
# changed-file filter:
dart analyze lib/ | grep -E "debug_response.dart|debug_sender.dart|response_viewer.dart"
NONE
```

## Notes on real `HttpServer` fixture

`test/request_debug_response_test.dart` runs under `TestWidgetsFlutterBinding`, which installs
an `HttpOverrides` returning HTTP 400 for every `HttpClient`. The truncation test therefore
runs `DebugSender` inside `HttpOverrides.runWithHttpOverrides(..., _RealHttpOverrides())` and
constructs the sender **inside** that zone (`IOClient` creates its `HttpClient` in its
constructor). This preserves a real `dart:io HttpServer` loopback fixture on the send path.

## Assertions proven

1. `>maxBodyBytes` response → `truncated == true`, `bodyBytes.length == maxBodyBytes`,
   `sizeBytes == Content-Length` (真实值 8MB+8192), from a real loopback server.
2. UI shows `已截断` badge and `response-size` equals real value; small response shows no badge.
3. Binary card click copies base64; `base64.decode(copied) == originalBytes` (byte-identical).
4. `rewriteRuleHeaders()` / saved `DebugRewriteRule.respHeaders` exclude
   `content-encoding`, `content-length`, `transfer-encoding`, `connection`, `keep-alive`,
   and `Connection`-listed custom tokens; keeps `content-type` / `x-extra`.
5. Error response (`error != null`) disables the save button; tapping yields no rule/confirm.
6. Large response falls back to chunked rendering with no exception.
