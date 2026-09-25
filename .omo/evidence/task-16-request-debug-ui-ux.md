# Task 16 — full-screen response body view, search only in full-screen

Plan: `.omo/plans/request-debug-ui-ux.md` todo 16.
User request: Body 可视区域太小 → 点击按钮全屏看详细数据；内嵌 Body 去掉搜索框；搜索框只在全屏显示。

## Change summary

`lib/page/request_debug/response_viewer.dart`
- Extracted a reusable stateful `_ResponseBodyPane` that owns `_visibleChars`, the four search
  fields (`_searchController` / `_searchQuery` / `_searchOffset` / `_searchMiss`), and the JSON
  `_collapsed` set. Parameters: `{rawText, bodyKind, format, sizeBytes, keyPrefix, showSearch,
  forceRaw, onFullscreen}`.
- Every content key is derived from `keyPrefix`: `-tree / -gutter / -collapse-<i> / -text /
  -more / -counter / -binary / -search / -search-input / -search-status / -fullscreen`.
- Inline Body uses `keyPrefix:'response-body'` with `showSearch:false` → **no**
  `response-body-search*` widgets in either the JSON-tree path or the chunked path.
  Inline Raw keeps `keyPrefix:'response-raw'`, `forceRaw:true`, no search.
- `_buildFullscreenBar` renders a `response-body-fullscreen` button when `onFullscreen != null`;
  `_openFullScreenBody` pushes `MaterialPageRoute(fullscreenDialog:true, ...)` via
  `Navigator.of(context, rootNavigator:false)` — no `showDialog` / hand-written bottom sheet.
- `_ResponseBodyFullScreen` = own `Scaffold` keyed `response-body-fullscreen-view` + `AppBar`
  ('响应体') + back button keyed `response-body-fullscreen-close`, body = the same pane with
  `keyPrefix:'response-fullscreen'`, `showSearch:true`.
- Search still runs over the **full** `bodyText`; a match outside the current chunk expands
  `_visibleChars` (reused `_searchSourceText` / `_onSearchChanged` logic, now in the pane).
- Pure helpers `_displayResponseBodyText` / `_searchResponseBodySource` (both accept `forceRaw`)
  are shared by the copy action and the pane; `_buildEmptyState` is a shared top-level widget.
- XML keeps its `prettyXml`; no new dependency; no pubspec change; theme tokens only.

`test/request_debug_response_test.dart`
- Removed the inline-search test; added: inline no-search for JSON tree + chunked text/plain,
  full-screen open/search-far-marker/close, full-screen >256KB chunked, full-screen malformed
  JSON fallback.

## TDD evidence

- RED: `flutter test test/request_debug_response_test.dart` → `+23 -5`, the 5 new cases fail
  (inline search present / fullscreen keys absent). Log: `.omo/evidence/task-16-red.txt`.
- GREEN: `flutter test test/request_debug_response_test.dart test/request_debug_editor_test.dart`
  → `+45: All tests passed!`. Log: `.omo/evidence/task-16-green.txt`.
- Regression: `flutter test test/request_debug_page_test.dart test/request_debug_history_test.dart
  test/request_debug_url_params_sync_test.dart test/request_debug_kv_editor_test.dart
  test/request_debug_body_editor_test.dart test/request_debug_sender_test.dart
  test/curl_codec_test.dart` → `+78: All tests passed!`.
- Static: `dart analyze lib/` → 729 total = 0 errors / 93 warnings / 636 infos == baseline
  (`.omo/evidence/task-16-analyze.txt`). Single file `dart analyze
  lib/page/request_debug/response_viewer.dart` → `No issues found!`.

## Acceptance mapping

| Criterion | Test |
| --- | --- |
| inline Body no `response-body-search`/`-input` (JSON) | `inline Body（JSON 树）不渲染搜索框，仅提供全屏入口` |
| inline Body no search (chunked text/plain) | `inline Body（分块纯文本）不渲染搜索框，仅提供全屏入口` |
| `response-body-fullscreen` opens `response-body-fullscreen-view` with `response-fullscreen-search-input` + body | `全屏查看：搜索基于完整 bodyText 并展开命中，关闭返回 Body` |
| far marker revealed by full-body search | same |
| close returns to Body, `takeException()==null` | same |
| >256KB JSON chunked in inline + full-screen (`response-body-more` / `response-fullscreen-more`) | `全屏查看：>256KB JSON 走分块路径，关闭无异常` |
| malformed JSON falls back plain in full-screen, no exception | `全屏查看：非法 JSON 回退纯文本无异常` |
| headers/cookies at 360dp no overflow | existing `360dp 下头部 / Cookie 表无溢出` (green) |

## Manual QA

`flutter test test/request_debug_response_test.dart test/request_debug_editor_test.dart` (45/45)
exercises the full flow: inline Body has no search, tapping the full-screen button mounts the
opaque route, typing a far marker in the full-screen search expands the visible chunk to include
it, and closing the route returns to the Body tab with no exception. Chunked / malformed / 256KB
fallbacks verified. No device run required for the widget-level behavior.

## Files / commit

- `lib/page/request_debug/response_viewer.dart`
- `test/request_debug_response_test.dart`
- `.omo/evidence/task-16-request-debug-ui-ux.md`
- `.omo/notepads/request-debug-ui-ux/learnings.md` (appended `[T16]`)

`dist/` untouched; `rust/**` untouched.
