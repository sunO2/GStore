# Task 15 — responsive editor shell, keyed overflow menu, single send, URL submit

- Plan: `.omo/plans/request-debug-ui-ux.md` todo 15
- HEAD at start: `eb53425`
- Status: DONE (RED captured, GREEN, analyze baseline, commit)

## Changed files

- `lib/page/request_debug/request_editor_page.dart` (product)
- `test/request_debug_editor_test.dart` (acceptance tests)
- `test/request_debug_url_params_sync_test.dart` (2 save taps routed through the menu + submit-segment adaptation)

## Acceptance criteria (all met)

1. Open `request-editor-more`, then tap `request-editor-save` / `request-editor-save-as` /
   `request-editor-export-curl` — each performs its action.
   → editor tests `保存写入精确字段…`, `另存为生成副本…`, `导出 cURL → 展示等价命令` (now via `_tapMore` helper).
2. `find.byKey(const Key('request-editor-send-top'))` findsNothing; exactly one send affordance.
   → editor test `仅一个发送入口：底部 request-editor-send，无顶部按钮`.
3. Shell renders with `takeException() == null` at 360x640.
   → editor test `窄屏 360x640：外壳渲染无异常且动作齐备`.
4. Tapping the URL row to open its sheet, then `receiveAction(TextInputAction.done)` commits the URL,
   closes the surface, and triggers EXACTLY ONE send — and the sent request carries the freshly-typed
   query params (sync-before-send).
   → editor test `URL 弹层 done：先同步新查询参数再发送，且仅发送一次`
   (asserts `sender.calls.length == 1`, `url == https://api.example/search`, `query` contains `a=1` & `b=2`).

## TDD evidence

### RED (before implementation)

Command:

```
flutter test test/request_debug_editor_test.dart test/request_debug_url_params_sync_test.dart
```

Result: `exit=1`, `+16 -9` (9 failures), all intended:

```
[E] 集合分区 … 文件夹新建请求 → 编辑器保存 …        (save key moved into menu)
[E] URL⇄参数同步 保存规范化 …                        (save key moved into menu)
[E] URL⇄参数同步 占位符字面保留 …                    (save key moved into menu)
[E] 请求编辑器 · 发送 仅一个发送入口 …               (request-editor-send-top still present)
[E] 请求编辑器 · 发送 URL 弹层 done …                (onSubmitted did not send)
[E] 请求编辑器 · 保存 保存写入精确字段 …             (save key moved into menu)
[E] 请求编辑器 · 保存 另存为生成副本 …               (save-as key moved into menu)
[E] 请求编辑器 · 保存 导出 cURL …                    (export key moved into menu)
[E] 设计系统约束 窄屏 360x640 …                      (request-editor-more absent)
```

### GREEN (after implementation)

Command:

```
flutter test test/request_debug_editor_test.dart test/request_debug_kv_editor_test.dart \
  test/request_debug_url_params_sync_test.dart test/request_debug_body_editor_test.dart \
  test/request_debug_history_test.dart
```

Result: `exit=0` → `00:05 +46: All tests passed!`

## Static analysis

```
dart analyze lib/
729 issues found.   (0 errors / 93 warnings / 636 infos == baseline)
```

- `grep request_editor_page.dart` → **no entries** (no new warning/info in the changed file).
- `grep 'error -'` → **no output** (0 errors).

## Implementation notes

- URL field: `textInputAction: TextInputAction.done` and
  `onSubmitted: (_) { _syncParamsFromUrl(); _send(); }` — the **explicit sync prefix is required**:
  `_composeDraft()` strips the URL query into `query[]`, so without the prefix a freshly typed
  `?a=1&b=2` would be dropped at send.
- Top bar: removed the duplicate `IconButton.filled` keyed `request-editor-send-top` (and its
  spacer) — the URL row now spans the freed width. The insert-variable affordance is kept in the
  URL sheet toolbar (`request-editor-insert-var`, via `_sheetToolbar(allowInsertVar: true)`).
- Bottom bar: `Expanded(FilledButton.icon 发送 key=request-editor-send)` stays the single primary
  action; `PopupMenuButton<String>` keyed `request-editor-more` hosts the preserved keys
  `request-editor-save` / `request-editor-save-as` / `request-editor-export-curl`. Capabilities and
  keys are NOT removed.
- All other adaptive fields now pass `TextInputAction.next` (KV value sheet, auth inline + sheet);
  the URL editor keeps `done`.
- Dirty guard: page `PopScope` unchanged and still covers unsaved edits made through the sheet
  (controller listeners via `_bindDirty` mark dirty); the full-screen surface keeps its own
  `_AppEditableFullScreen` `PopScope` + confirm sheet. The existing leave-guard test passes.
- Submit-surface consequence: `AppEditableField._commitSheet` invokes `onSubmitted` for BOTH the
  sheet 完成 button and the IME action. Therefore confirming the URL sheet also syncs-then-sends and
  auto-switches to the Response segment. `test/request_debug_url_params_sync_test.dart`'s
  `_setUrlViaSheet` helper now re-selects the Parameters segment after submit so its sync-only
  assertions remain valid. No product semantics beyond the mandated submit surface changed
  (`_composeDraft` / save / send / query_codec / sender / KV / body logic untouched).

## Raw excerpts

### RED tail

```
00:02 +8 -4: … 请求编辑器 · 发送 仅一个发送入口：底部 request-editor-send，无顶部按钮 [E]
00:03 +8 -5: … 请求编辑器 · 发送 URL 弹层 done：先同步新查询参数再发送，且仅发送一次 [E]
00:05 +16 -9: Some tests failed.
```

### GREEN tail

```
00:05 +45: … 设计系统约束 窄屏 360x640：外壳渲染无异常且动作齐备
00:05 +46: All tests passed!
```
