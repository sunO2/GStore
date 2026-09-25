# T9 — response viewer: AppTabBar + AppPillToggle

Task: plan todo 9 `.omo/plans/request-debug-ui-ux.md`
Base HEAD at start: `b2fdd2c` (worktree already carried a later commit `9ad6931` and unrelated in-progress edits; see "Scope discipline").
Commit message: `refactor(request-debug): use AppTabBar/AppPillToggle in the response viewer`

## Changed files (staged only)
- `lib/page/request_debug/response_viewer.dart` — swap the two switchers; remove horizontal scroll wrapper.
- `test/request_debug_response_test.dart` — add the "换一次响应 → 回到 Body 默认态" regression test.
- `.omo/evidence/task-9-request-debug-ui-ux.md` — this file (force-added; `.omo/` is gitignored).

## What changed
1. **格式化/原始 toggle** (`_buildHeader`, old `:245-264`): `AppSegmentedButton<ResponseBodyFormat>` → `AppPillToggle<ResponseBodyFormat>` (dropped `density:`). Keys preserved: `response-format-formatted`, `response-format-raw`. `onChanged` still resets `_visibleChars`.
2. **4-tab switch** (`_buildTabBody`, old `:315-362`): `AppSegmentedButton<ResponseViewerTab>` wrapped in `Align` + `SingleChildScrollView(horizontal)` → bare `AppTabBar<ResponseViewerTab>` inside the existing `Padding`. Both the `Align` and the `SingleChildScrollView` wrapper were removed (AppTabBar's Material `TabBar` is itself `isScrollable` + start-aligned). Keys preserved: `response-tab-headers`, `response-tab-body`, `response-tab-cookies`, `response-tab-raw`. `onChanged` unchanged (`_tab` + `_visibleChars` reset).
3. **didUpdateWidget sync**: no code change needed — `_tab`/`_format` stay the single controlled source of truth, so the rebuilt `AppTabBar`/`AppPillToggle` pick up the reset `value` on the same frame. `AppTabBar.didUpdateWidget` assigns `_controller.index` directly (programmatic sync, no `onChanged`) — see T3 note in notepad. `_visibleChars` reset at `:94` unchanged.

No body/header/cookie rendering logic, JSON pretty-printing, imports, or theme tokens were touched.

## Baseline (BEFORE change) — green
```
$ flutter test test/request_debug_response_test.dart
00:02 +15: All tests passed!
```
`dart analyze lib/` baseline for this plan: 0 errors / 93 warnings / 636 infos (729 total).

## After change
```
$ flutter test test/request_debug_response_test.dart
00:02 +16: All tests passed!          # +1 new reset test

$ dart analyze lib/page/request_debug/response_viewer.dart
Analyzing response_viewer.dart...
No issues found!

$ dart analyze lib/
729 issues found.   # errors: 0 / warnings: 93 / infos: 636  → identical to baseline, no NEW issue
```
(`grep -c response_viewer` in the full analyze output → NONE.)

## QA scenarios
- Happy: `response-format-raw` tap toggles the rendered body (existing test `application/json → 格式化缩进；原始为单行原文`); `response-tab-raw`, `response-tab-cookies`, `response-tab-headers` each show their body (existing tests) — all pass.
- Failure/reset: new test pumps response A, selects 原始 tab + 原始 format, then pumps response B; asserts viewer returns to Body + formatted and `tester.takeException() == null`. Passes.

## Scope discipline
- `git add` explicitly named the three paths above; `dist/` and the unrelated in-progress edits (`curl_codec.dart`, `debug_sender.dart`, `request_debug_page.dart`, their tests, `test/app_editable_field_test.dart`) were NOT staged.
- `AppTabBar`/`AppPillToggle`/`AppSegmentedButton`/`AppSegment` bodies untouched.
- No dependency/pubspec/version change.
