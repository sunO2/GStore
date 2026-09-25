# Task 5 — AppEditorToolbar / AppSuggestionChips (request-debug-ui-ux)

- **Repo**: /home/hezhihu89/develop/flutter/project/GStore
- **Base HEAD**: dfdc11d
- **Plan todo**: `.omo/plans/request-debug-ui-ux.md` §5 "design: add AppEditorToolbar and AppSuggestionChips (+ format callback slot)"
- **Changed files**:
  - `lib/core/design/app_components.dart` (APPEND `AppEditorToolbar` + `AppSuggestionChips`; + `import 'package:flutter/services.dart';`)
  - `test/app_editor_toolbar_test.dart` (NEW)
- **No** dependency added, **no** `pubspec.yaml` change. **No** `viewInsets` padding / keyboard overlay. Existing primitives untouched.

## TDD evidence

### RED — before implementation (classes undefined)

Command: `flutter test test/app_editor_toolbar_test.dart`

```
test/app_editor_toolbar_test.dart:45:17: Error: The function 'AppEditorToolbar' isn't defined.
test/app_editor_toolbar_test.dart:173:11: Error: The function 'AppSuggestionChips' isn't defined.
...
Failing tests:
  /home/hezhihu89/develop/flutter/project/GStore/test/app_editor_toolbar_test.dart: loading ...
```

### GREEN — after implementation

Command: `flutter test test/app_editor_toolbar_test.dart`

```
00:00 +0: AppEditorToolbar paste 从剪贴板写入绑定 controller
00:00 +1: AppEditorToolbar clear 清空 controller
00:00 +2: AppEditorToolbar insert-at-cursor 在选区插入 / 替换选中
00:00 +3: AppEditorToolbar 未提供 insertText 时不渲染插入按钮
00:00 +4: AppEditorToolbar onFormat 在提供时被调用
00:00 +5: AppEditorToolbar 未提供 onFormat 时不渲染格式化按钮
00:00 +6: AppEditorToolbar prev/next 回调被调用
00:00 +7: AppSuggestionChips 渲染 2 个 chip，点按一个把值写入 controller
00:00 +8: AppSuggestionChips onSelected 在点按时收到选中值
00:00 +9: AppSuggestionChips 空列表不渲染 chip row 且无异常
00:01 +10: All tests passed!
```

## Acceptance criteria mapping

| Criterion | Test | Result |
| --- | --- | --- |
| paste sets controller text from mocked clipboard | `paste 从剪贴板写入绑定 controller` (mock `Clipboard.getData`) | PASS |
| clear empties it | `clear 清空 controller` | PASS |
| insert-at-cursor inserts at the selection (replace selection) | `insert-at-cursor 在选区插入 / 替换选中` | PASS |
| `onFormat` invoked when provided | `onFormat 在提供时被调用` | PASS |
| prev/next callbacks invoked (callback-level) | `prev/next 回调被调用` | PASS |
| `AppSuggestionChips(['Content-Type','Authorization'])` renders 2 chips + tap sets text | `渲染 2 个 chip，点按一个把值写入 controller` | PASS |
| empty list renders no chip row + no exception | `空列表不渲染 chip row 且无异常` | PASS |

Extra guard tests: insert button absent when `insertText == null`; format button absent when `onFormat == null`;
`onSelected` fires with the tapped value.

## Static analysis gate

Command: `dart analyze lib/`

```
729 issues found.
```
- errors: **0** (baseline 0)
- warnings: **93** (baseline 93)
- infos: **636** (baseline 636)
- Highest `app_components.dart` diagnostic line = 1263 (legacy); NO diagnostic inside the newly added range (≥ 1951). => no NEW issues.

## Behavior / API notes

- `AppEditorToolbar.insertAtCursor(controller, text)` — public static helper: inserts at current selection
  (replacing it); invalid selection appends to end, so an empty controller ends up assigned the text.
- Paste = `Clipboard.getData(Clipboard.kTextPlain)` then insert-at-cursor.
- Optional slots (`insertText`, `onFormat`, `onPrevious`, `onNext`) render their button only when provided;
  paste/clear always render. Buttons keyed `editor-toolbar-{prev,next,paste,insert,format,clear}`.
- `AppSuggestionChips(suggestions, {required controller, onSelected})` — suggestions positional; empty => `SizedBox.shrink()`.
- Theme tokens only (`AppSpacing`, `AppTypography`, `Theme.of(context).textTheme`, Material theme defaults);
  no hardcoded colors. `flutter_tabler_icons` icons: chevron_left/right, clipboard, variable, braces, eraser.
- In-surface only: no `viewInsets` padding, no overlay above the keyboard (AppSheet family owns insets).
