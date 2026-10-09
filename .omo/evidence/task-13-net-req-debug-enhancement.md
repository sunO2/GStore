# Task 13 — save() result handling, copyWith sentinel, overrides / custom method / dirty flag (evidence)

Plan: `.omo/plans/net-req-debug-enhancement.md` todo 13
Commit: `fix(request-debug): surface save failures and preserve fields`

## Scope / what changed

| Item | Fix | File |
| --- | --- | --- |
| `facade.save()` boolean ignored | Every caller now checks the returned `bool`; on `false` shows unified `AppDialogs.showError('保存失败，改动未写入磁盘')` and (editor) keeps `_dirty` | `request_editor_page.dart`, `collection_section.dart`, `environment_section.dart`, `history_section.dart` |
| Editor save-success wording | **Unchanged** (`请求已保存` / `已另存为新请求`); only the failure branch was added before it | `request_editor_page.dart` |
| `copyWith` could not clear nullable fields | Sentinel `_unset` (`const Object()`): omitted → keep original; explicit `null` → clear. Applied to `DebugRequest` nullable fields (`auth`/`overrides`/`collectionId`/`binaryFilePath`/`timeoutMs`/`followRedirects`/`useCookieJar`/`skipTlsVerify`) and `DebugAuth` (`username`/`password`/`token`/`apiKeyName`/`apiKeyValue`/`apiKeyIn`) | `debug_models.dart` |
| `_composeDraft` dropped `overrides` | `overrides: widget.request?.overrides` propagated into the rebuilt draft | `request_editor_page.dart` |
| Non-standard HTTP method reset to `GET` | Removed the `if (!_httpMethods.contains(_method)) _method = 'GET'` reset; dropdown items now append the custom method so `DropdownButton` keeps it | `request_editor_page.dart` |
| Body toolbar clear/paste / name change did not mark dirty | `_body` (and `_name`) now bound via `_bindDirty` → controller listener fires on programmatic `clear()`/`insertAtCursor`, so leaving prompts | `request_editor_page.dart` |
| `addRequest` null (unknown collection) silently ignored | `_save` now fails visibly instead of dropping the request | `request_editor_page.dart` |
| Send path save result | `_send` checks `save()` and surfaces `保存失败，历史未写入磁盘` on failure | `request_editor_page.dart` |

The production facade already reported save failure via `reportSaveError`; the added
per-caller checks make each **section** own its failure path and are what the tests assert
(section fake facades override `save()` and do not self-report).

## TDD — RED first (before source edits)

Command:

```
LD_LIBRARY_PATH=/tmp flutter test test/request_debug_save_failure_test.dart test/request_debug_editor_test.dart
```

Raw captured output (pre-fix):

```
00:05 +21 -8: ...request_debug_editor_test.dart: 请求编辑器 · 字段保真与脏标记 保存保留 overrides（_composeDraft 不丢失） [E]
  Expected: not null
    Actual: null
  (line 1029)

00:06 +21 -9: ...request_debug_editor_test.dart: 请求编辑器 · 字段保真与脏标记 非标准 HTTP 方法（PROPFIND）保留并可保存 [E]
  Expected: 'PROPFIND'
    Actual: 'GET'

00:06 +22 -10: ...request_debug_editor_test.dart: 请求编辑器 · 字段保真与脏标记 body 工具栏清空后标记脏值：返回弹出未保存确认 [E]
  Expected: exactly one matching candidate
    Actual: _TextWidgetFinder:<Found 0 widgets with text "放弃未保存的修改？": []>

00:06 +22 -10: Some tests failed.

Failing tests:
  .../request_debug_editor_test.dart: ... body 工具栏清空后标记脏值：返回弹出未保存确认
  .../request_debug_editor_test.dart: ... 保存保留 overrides（_composeDraft 不丢失）
  .../request_debug_editor_test.dart: ... 非标准 HTTP 方法（PROPFIND）保留并可保存
  .../request_debug_save_failure_test.dart: copyWith 哨兵：支持清空可空字段 DebugAuth.copyWith 支持清空 username/password/token/apiKey 字段
  ... and 6 more
```

The 6 additional REDs were:

- `request_debug_save_failure_test.dart` — editor / collection / environment / history save
  failure tests failed (no error shown; editor still showed success `请求已保存`).
- `request_debug_save_failure_test.dart` — `DebugRequest.copyWith(auth: null, overrides: null)`
  returned the original non-null values; `DebugRequest.copyWith(...network options null)` did not clear.
- `request_debug_save_failure_test.dart` — `DebugAuth.copyWith(username: null, ...)` did not clear.

Exit status: `+24 -10: Some tests failed.`

## GREEN — after fixes

Required command (5 files):

```
LD_LIBRARY_PATH=/tmp flutter test test/request_debug_save_failure_test.dart test/request_debug_editor_test.dart \
  test/request_debug_store_test.dart test/request_debug_facade_test.dart test/request_debug_history_test.dart
```

Raw output saved to `.omo/evidence/task-13-green.txt`; tail:

```
00:06 +67: ...request_debug_editor_test.dart: 设计系统约束 窄屏 360x640：外壳渲染无异常且动作齐备
00:06 +68: All tests passed!
```

Broader request-debug regression set (15 files: editor/history/facade/store/secrets/cookie/
sender/response/rules/body/auth/history-response/prefill/shared-store):

```
00:15 +256: All tests passed!
```

## Static analysis

```
dart analyze lib/core/request_debug/debug_models.dart lib/page/request_debug/request_editor_page.dart \
  lib/page/request_debug/collection_section.dart lib/page/request_debug/environment_section.dart \
  lib/page/request_debug/history_section.dart
Analyzing debug_models.dart, request_editor_page.dart, collection_section.dart, environment_section.dart, history_section.dart...
No issues found!
```

(Full log: `.omo/evidence/task-13-analyze.txt`.) `dart analyze lib/` still reports the
project-wide 729 pre-existing info/warnings; **no new issue in any changed lib file**.
The two diagnostics in `test/request_debug_editor_test.dart` (unused `flutter_tabler_icons`
import, `use_super_parameters` hint) are pre-existing and untouched by this task.

## Notes / honest limitations

- Sentinel parameters are typed `Object?` on the two models; the intended contract is
  documented on each `copyWith`. Non-null call sites are unchanged in behaviour.
- Custom HTTP methods are preserved through the editor; the dropdown only renders the
  custom value alongside the standard set (no free-text method entry was added).
- Dirty-flag fix relies on `TextEditingController` listeners; the existing `onChanged`
  handlers are kept, so keyboard edits remain dirty as before.
- This task does **not** change the save-success wording, dialog APIs, shared components,
  `pubspec.yaml`, or version.

## Files touched

- `lib/core/request_debug/debug_models.dart`
- `lib/page/request_debug/request_editor_page.dart`
- `lib/page/request_debug/collection_section.dart`
- `lib/page/request_debug/environment_section.dart`
- `lib/page/request_debug/history_section.dart`
- `test/request_debug_save_failure_test.dart` (new)
- `test/request_debug_editor_test.dart` (extended)
- `.omo/evidence/task-13-net-req-debug-enhancement.md`
- `.omo/evidence/task-13-green.txt`
- `.omo/evidence/task-13-analyze.txt`
