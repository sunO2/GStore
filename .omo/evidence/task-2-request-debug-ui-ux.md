# Task 2 — debug_sender + curl_codec merge-based override (evidence)

Plan: `.omo/plans/request-debug-ui-ux.md` todo 2
Commit message: `fix(request-debug): override duplicate query keys in send and cURL export`
HEAD before: `b2fdd2c`

## Commands & results

### TDD RED — before product-code edits
```
$ flutter test test/request_debug_sender_test.dart test/curl_codec_test.dart
00:00 +39 -5: Some tests failed.

Failing tests:
  test/curl_codec_test.dart: effectiveUrl（合并覆盖 + fragment 顺序） 同名查询键覆盖 URL 已有键（非追加）
  test/curl_codec_test.dart: effectiveUrl（合并覆盖 + fragment 顺序） 查询串位于 fragment 之前
  test/curl_codec_test.dart: effectiveUrl（合并覆盖 + fragment 顺序） 覆盖可扩展为同名的多个值
  test/request_debug_sender_test.dart: DebugSender query merge (override) an override may expand to multiple values for the same key
  test/request_debug_sender_test.dart: DebugSender query merge (override) overrides a duplicate query key from the URL
```
Raw pre-fix assertions:
- sender override: `Expected: 'a=2'  Actual: 'a=1&a=2'` (append bug)
- sender multi:  `Expected: 'a=2&a=3'  Actual: 'a=1&a=2&a=3'` (append bug)
- effectiveUrl:  `Expected: 'https://x/p?a=2#frag'  Actual: 'https://x/p#frag?a=2'` (fragment ordering bug)

### TDD GREEN — after implementation
```
$ flutter test test/request_debug_sender_test.dart test/curl_codec_test.dart
00:00 +44: All tests passed!
```

### Static gate
```
$ dart analyze lib/
636 info - 
 93 warning - 
729 issues found.   (0 errors)
```
Baseline is 0 errors / 93 warnings / 636 infos → **no new issue**. No analyze entry references
`debug_sender.dart` or `curl_codec.dart`.

## Acceptance mapping

| Acceptance criterion | Where asserted | Result |
| --- | --- | --- |
| url `?a=1` + query `[a=2]` → server `a=2` (override, not `a=1&a=2`) | `request_debug_sender_test.dart` › "overrides a duplicate query key from the URL" (`fixture.recorded.single.query`) | PASS |
| url `?a=1` + query `[a=2,a=3]` → `a=2&a=3` | sender › "an override may expand to multiple values for the same key" | PASS |
| url `?a=1` + no query → `a=1` | sender › "keeps URL-only query keys when there is no override" | PASS |
| url `?flag` + no query → `flag` preserved | sender › "preserves a valueless query key" | PASS |
| `effectiveUrl(url:'https://x/p#frag', query:[a=2]) == 'https://x/p?a=2#frag'` | `curl_codec_test.dart` › "查询串位于 fragment 之前" (+ `isFalse` on `#frag?a=2`) | PASS |
| `buildUri('http://x/p#f',[a=2]).toString() == 'http://x/p?a=2#f'` | `curl_codec_test.dart` › "buildUri 同样把查询串放在 fragment 之前" | PASS |
| End-to-end `DebugRequest(url:'<origin>/p', query:[a=2])` via `DefaultRequestDebugFacade` records `a=2` (no duplicate) | `request_debug_sender_test.dart` › "DefaultRequestDebugFacade end-to-end query merge records the merged query on the server (no duplicate)" | PASS |
| `url:'{{host}}/p?a=1'` with no active env → `send` returns `DebugResponse`, no throw | sender › "placeholder URL with no active env returns a response, never throws" (`isA<DebugResponse>()` + `error isNotNull`) | PASS |
| `DebugSender.send` signature / error normalization unchanged | Signature untouched; only `_buildUri` body delegated to `query_codec.buildUri`; `send`/`_perform`/`_describeError` unmodified | PASS |
| No encoding re-implemented outside `query_codec.dart` | `effectiveUrl` now = `parseUrlQuery` + `mergeParams` + `rebuildUrl`; `_buildUri` = `buildUri`; removed the old `Uri.encodeQueryComponent` join | PASS |

## Files changed
- `lib/core/request_debug/debug_sender.dart` — `_buildUri` delegates to `query_codec.buildUri`; added `query_codec.dart` import.
- `lib/core/request_debug/curl_codec.dart` — `effectiveUrl` reuses `parseUrlQuery`/`mergeParams`/`rebuildUrl` (query before `#fragment`); added `query_codec.dart` import.
- `test/request_debug_sender_test.dart` — new `DebugSender query merge (override)` + `DefaultRequestDebugFacade end-to-end query merge` groups.
- `test/curl_codec_test.dart` — new `effectiveUrl（合并覆盖 + fragment 顺序）` group + `buildUri` ordering assertion.

## Notes / risks
- `DebugQueryParam` cannot distinguish `?a=` from `?a`; rebuild emits a bare name for empty values, so the `?flag` assertion expects `flag` (consistent with T1).
- `{{host}}` URL is percent-encoded by `Uri` inside `buildUri`; `send` normalizes the resulting failure into `DebugResponse.error` (verified no throw).
- Sibling workers left an unrelated uncommitted change in `lib/core/design/app_components.dart`; it was NOT staged.
