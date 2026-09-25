# Task 10 — request editor: adaptive inputs + toolbar/chips

Plan: `.omo/plans/request-debug-ui-ux.md` todo 10
HEAD before: `f3411a3`
Scope: `lib/page/request_debug/request_editor_page.dart`, `test/request_debug_editor_test.dart`, `test/request_debug_history_test.dart`

## What changed

- URL, `_field`-based auth inputs, and KV key/value fields now use `AppEditableField`.
  - `inline`: KV key (name) fields, auth username/password, auth apiKey name.
  - `sheet`: URL, auth token, auth apiKey value, KV value fields.
  - Body (`request-editor-body`) and request name (`request-editor-name`) stay raw `TextField`s.
- Each field binds the SAME existing page controllers (`_url`, `_authUser`, `_authPass`,
  `_authToken`, `_authKeyName`, `_authKeyValue`, `_KvRow.nameCtrl/valueCtrl`), so
  `_composeDraft()` remains the single source of truth. `_composeDraft` mapping untouched.
- Dirty tracking: `_bindDirty(controller)` listeners mark dirty + `setState` on any text
  change, so sheet commits (which bypass `onChanged`) still trigger the unsaved-leave
  guard AND refresh the env preview (`request-editor-url-preview`).
- `AppEditorToolbar` wired inside every `AppEditableField` sheet via `toolbarBuilder`:
  paste/clear built in, prev/next call `_focusRelative` to move focus among the mounted
  editor fields (`AppEditableFieldState.focus()`), format slot left as the todo-14 hook.
- `AppSuggestionChips` wired in the header-value sheet: common header names + recent
  values derived from `store.history` (`_headerSuggestions()`), inserted at the draft
  cursor (`AppEditorToolbar.insertAtCursor`).
- Insert-variable: picker moved into the URL sheet toolbar, key `request-editor-insert-var`
  preserved; selection now inserts into the ACTIVE controller (sheet draft) via the
  toolbar static, never a stale `_url.selection`.
- Preserved keys: `request-editor-url` (KeyedSubtree wrapper), `request-editor-url-preview`,
  `request-editor-env-missing-*`, `request-editor-insert-var`. No custom
  `SingleChildScrollView`, no `viewInsets` padding (AppSheet/AppSheetScaffold own it).

## TDD evidence

### RED (tests updated first, before product change)

`flutter test test/request_debug_editor_test.dart test/request_debug_history_test.dart`

```
00:04 +16 -7: Some tests failed.
Failing tests:
  request_debug_editor_test.dart: 请求编辑器 · 保存 保存写入精确字段，且保存后离开不再二次确认
  request_debug_editor_test.dart: 未保存离开二次确认 有未保存编辑时返回 → ...
  request_debug_editor_test.dart: 环境变量 弹层内插入变量 → 命中弹层草稿（不写旧选区）
  request_debug_editor_test.dart: 环境变量 AppSuggestionChips 含 store.history 派生的最近值
  request_debug_editor_test.dart: 环境变量 工具栏 prev/next 在编辑器字段间移动焦点
  ... and 3 more (incl. request_debug_history_test.dart URL read)
```

### GREEN

`flutter test test/request_debug_editor_test.dart test/request_debug_history_test.dart`

```
00:04 +24: All tests passed!
```

Regression surface:
`flutter test test/request_debug_page_test.dart test/request_debug_response_test.dart test/app_editable_field_test.dart test/app_editor_toolbar_test.dart test/app_sheet_test.dart`

```
00:05 +47: All tests passed!
```

## Static gate

`dart analyze lib/` → `0 errors / 93 warnings / 636 infos` (== HEAD baseline `f3411a3`).
No analyzer entries for `request_editor_page.dart`.

## Acceptance mapping

- tapping `request-editor-url` opens `request-editor-field-sheet` — new focus test + all URL flows.
- enter in `request-editor-field-sheet-input` + `request-editor-field-sheet-confirm` updates
  the field and `request-editor-url-preview` — save/env/insert tests.
- unsaved-leave guard still triggers — `有未保存编辑时返回...` (commit then back → confirm sheet).
- env-missing chips still render — `已定义解析、未定义保留并标记...`.
- insert-variable while sheet open lands in the sheet value — `弹层内插入变量...`.
- toolbar prev/next moves focus (`FocusNode.hasFocus`) — `工具栏 prev/next...`.
- `AppSuggestionChips` includes a `store.history`-derived value — `AppSuggestionChips 含...`.

## Notes / risks

- `AppEditableField` display uses a constant inner key `request-editor-field-display`;
  page tests disambiguate via wrapper keys (`request-editor-url`, `request-editor-header-value-0`).
- KV fields gained keys `request-editor-<kind>-name-N` / `-value-N` to keep the sheet
  target deterministic for todo 13; todo 13 may replace these with stable row ids.
- No pubspec/version change, no new dependency, `dist/` untouched.
