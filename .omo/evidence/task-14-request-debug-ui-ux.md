# Task 14 — request debug body JSON format

## Task
Plan todo 14 (`request-debug-ui-ux`): OWN the body format action. In
`lib/page/request_debug/request_editor_page.dart`, add a button keyed
`request-editor-body-format` shown only when `bodyKind == json` that validates
via `jsonDecode`; on success pretty-prints with 2-space indent into the body
controller; on failure shows an inline error keyed
`request-editor-body-format-error`. `AppEditorToolbar.onFormat` must call the
SAME function (single source of truth). No auto-format per keystroke.

## Changed files
- `lib/page/request_debug/request_editor_page.dart`
  - `import 'dart:convert';`
  - new field `String? _bodyError;`
  - new `void _formatBodyJson()` (single source of truth)
  - `_buildBodyEditor`: dropdown row + `request-editor-body-format` IconButton
    (json only) + `AppEditorToolbar(controller: _body, onFormat: ...)` +
    inline `request-editor-body-format-error` + body TextField error clearing.
- `test/request_debug_body_editor_test.dart` (NEW, 5 cases)

## Implementation notes
- Pretty print: `const JsonEncoder.withIndent('  ').convert(jsonDecode(raw))`.
- Failure path leaves `_body` untouched, only sets `_bodyError`.
- Error cleared on successful format, on body edit, and on body-kind change.
- `AppEditorToolbar.onFormat` is `null` for non-JSON kinds, so neither
  `editor-toolbar-format` nor `request-editor-body-format` render.
- Decoupled from `response_viewer.dart` (`tryPrettyJson` NOT imported).

## TDD evidence
### RED (before implementation)
```
flutter test test/request_debug_body_editor_test.dart
00:01 +0 -3 ... (invalid/format/toolbar cases fail; dedicated key not found)
00:02 +1 -4: Some tests failed.
Failing tests (4): invalid error, valid format, toolbar onFormat, error-clears-on-edit
```
### GREEN (after implementation)
```
flutter test test/request_debug_body_editor_test.dart
00:01 +0: 非法 JSON 显示 request-editor-body-format-error 且 body 不变
00:01 +1: 合法 JSON 点按 request-editor-body-format → 2 空格美化输出
00:01 +2: AppEditorToolbar.onFormat 与专用按钮走同一函数（单一事实来源）
00:01 +3: 非 JSON body 类型不显示格式化入口
00:01 +4: 再次编辑后错误清除
00:01 +5: All tests passed!
```
### Combined acceptance command
```
flutter test test/request_debug_body_editor_test.dart test/request_debug_editor_test.dart
00:04 +19: All tests passed!
```

## Analyze
```
dart analyze lib/
729 issues found  =>  0 errors / 93 warnings / 636 infos  (== baseline 729)
grep request_editor_page => NONE
```

## QA scenarios
- happy: valid JSON body -> format button produces exact 2-space pretty output.
- failure: invalid JSON -> `request-editor-body-format-error` shown, body
  unchanged, `takeException() == null`.
- single source of truth: `AppEditorToolbar.onFormat` yields the identical
  pretty output as the dedicated button.

## Cleanup / risks
- Did not touch send/save mapping, KV rows, or the segment switch (outside scope).
- T15 edits this same file (shell/overflow/submit-send) — no overlapping edits here.
- Concurrency: staged only explicit paths; `dist/` never staged.
