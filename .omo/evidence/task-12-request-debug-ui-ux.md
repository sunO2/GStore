# task-12 · request-debug UI/UX — URL ⇄ params commit-driven sync + canonical persistence

**Plan todo:** 12 — `request_editor_page.dart`: commit-driven URL⇄params sync + canonical path+fragment persistence
**HEAD at start:** 7daa7e2
**Depends on:** T1 (query_codec), T2 (sender/cURL), T10 (adaptive inputs)

## TDD

### RED (before implementation)

`flutter test test/request_debug_url_params_sync_test.dart`

```
00:03 +0 -8: Some tests failed.
Failing tests:
  .../test/request_debug_url_params_sync_test.dart: URL⇄参数同步 载入 url ?a=1 + query [a=2] → 行恰为 [a=2]
  .../test/request_debug_url_params_sync_test.dart: URL⇄参数同步 载入 legacy url ?a=1&b=2 + query [a=2] → 行 [a=2, b=2]（保留 URL 独有键）
  .../test/request_debug_url_params_sync_test.dart: URL⇄参数同步 提交 URL ?a=1&b=2 → 2 行
  .../test/request_debug_url_params_sync_test.dart: URL⇄参数同步 编辑行值 → URL 仅更新一次（无振荡）
  .../test/request_debug_url_params_sync_test.dart: URL⇄参数同步 保存规范化：url = path#frag（无 ?），query 精确；重载行一致
  .../test/request_debug_url_params_sync_test.dart: URL⇄参数同步 占位符字面保留：跳过同步解析，保存后 url/query 仍含 {{...}}
  .../test/request_debug_url_params_sync_test.dart: URL⇄参数同步 · QA 3 次连续编辑稳定（无振荡）
  .../test/request_debug_url_params_sync_test.dart: URL⇄参数同步 · QA 非法 / 局部 URL 提交不抛且行不变
```

Red evidence: `.omo/evidence/task-12-red.txt`

### GREEN (after implementation)

`flutter test test/request_debug_url_params_sync_test.dart`
```
00:02 +8: All tests passed!
```
Evidence: `.omo/evidence/task-12-sync-green.txt`

### Required build gate (trio)

`flutter test test/request_debug_url_params_sync_test.dart test/request_debug_editor_test.dart test/request_debug_history_test.dart`
```
00:05 +32: All tests passed!
```
Evidence: `.omo/evidence/task-12-trio-green.txt`

### Broader regression (all request-debug + codec tests)

`flutter test test/request_debug_*_test.dart test/query_codec_test.dart test/curl_codec_test.dart`
```
00:18 +201: All tests passed!
```
Evidence: `.omo/evidence/task-12-regression.txt`

### Static gate

`dart analyze lib/`
```
729 issues found.
errors: 0
warnings: 93
infos: 636
request_editor_page.dart entries: 0
```
Exact baseline (0E/93W/636I), no new issues on touched file.
Evidence: `.omo/evidence/task-12-analyze.txt`

## Implementation

`lib/page/request_debug/request_editor_page.dart`:

1. **initState always parses the URL** via `parseUrlQuery(request.url)`; `initialParams =
   request.query.isEmpty ? parsed.params : mergeParams(parsed.params, request.query)`.
   URL field seeded with `rebuildUrl(parsed.base, parsed.fragment, initialParams)` so the
   UI always shows the merged `path?query#fragment`. `{{var}}` never resolved here.
2. **Single `_syncing` reentrancy guard**; no `addListener` drives sync.
3. **`_syncUrlFromParams()`** (params → URL, commit-driven): rebuilds display URL from the
   current param rows, keeping `path`/`#fragment`. Called on param row commit
   (`onSubmitted` of the row name inline field and value sheet), on add and on delete.
4. **`_syncParamsFromUrl()`** (URL → params, commit-driven): parses the committed URL,
   `mergeParams(currentParams, parsed.params)` (newest URL wins on same name; URL-only keys
   appended; param-only keys retained), reconciles rows in place (`_applyParamRows`),
   rewrites the display URL. Wired to the URL `AppEditableField.onSubmitted`. This is the
   explicit step T15 must call before send.
5. **Canonical `_composeDraft`**: `url = rebuildUrl(parsed.base, parsed.fragment, [])`
   (query stripped, fragment kept); `query = _currentParams()`.
6. `_currentParams()` extracted so compose and sync share one mapping.

`test/request_debug_editor_test.dart`: `_FakeSender` now records `query` (enabled, non-empty
names as `name=value`). One stale expectation in the env-non-recursion test updated:
committing a query-less URL now retains the canonical `m={{missing}}` param row (union
merge, matching the "partial URL leaves rows unchanged" acceptance), so the preview is
`{{host}}?m={{missing}}` — still proving `{{host}}` is not recursively resolved.

## Acceptance mapping

| Criterion | Test |
| --- | --- |
| load `?a=1` + query `[a=2]` → rows exactly `[a=2]` | `载入 url ?a=1 + query [a=2] → 行恰为 [a=2]` |
| legacy `?a=1&b=2` + query `[a=2]` → `[a=2, b=2]` | `载入 legacy url ...` |
| commit URL `?a=1&b=2` → 2 rows | `提交 URL ?a=1&b=2 → 2 行` |
| edit row value → URL once | `编辑行值 → URL 仅更新一次（无振荡）` |
| save: no `?`, equals `path#frag`, exact query | `保存规范化 ... 重载行一致` |
| reload → identical rows | same test (second `_pumpEditor`) |
| `{{host}}/{{missing}}` literal; draft still contains them | `占位符字面保留 ...` |
| merge stable over 3 sequential edits | `3 次连续编辑稳定（无振荡）` |
| partial/invalid URL commit no-throw, rows unchanged | `非法 / 局部 URL 提交不抛且行不变` |

## QA

- Oscillation: asserted after extra `tester.pump()` frames in both edit tests — no rebind.
- Invalid `?x=%ZZ` (malformed percent) → `parseUrlQuery` catch boundary → rows unchanged,
  `takeException() == null`.
- Placeholder resolution deferred: URL field and persisted `url`/`query` keep `{{...}}`;
  only `_send` resolves (untouched).
