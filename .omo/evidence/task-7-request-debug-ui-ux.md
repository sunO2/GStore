# Task 7 — request_debug page: 4-section switch → AppTabBar

Plan: `.omo/plans/request-debug-ui-ux.md` todo 7
Commit subject: `refactor(request-debug): use AppTabBar for the workbench sections`

## Change

`lib/page/request_debug/request_debug_page.dart` — `_buildSectionSwitch` now renders
`AppTabBar<RequestDebugSection>` instead of `AppSegmentedButton<RequestDebugSection>`
wrapped in `Align` + horizontal `SingleChildScrollView`. The `AppTabBar` itself uses
`TabBar(isScrollable: true, tabAlignment: TabAlignment.start)` so narrow screens scroll
natively and a wide selected label no longer stretches its siblings.

Removed:
- outer `SingleChildScrollView(scrollDirection: Axis.horizontal)` (AppTabBar scrolls itself)
- redundant `Align(alignment: Alignment.centerLeft)` (`TabAlignment.start` handles left align)
- `density: AppSegmentedButton.mediumDensity` (not part of the AppTabBar API)

Preserved (per todo constraints):
- key `request-debug-section-switch`
- segment keys `request-debug-segment-collections|history|environments|rules`
- labels `集合 / 历史 / 环境 / 改写规则`
- the `_buildSectionBody` `switch (_section)` body — untouched
- `onChanged: (section) => setState(() => _section = section)`

Doc comments in the same file updated from `[AppSegmentedButton]` → `[AppTabBar]`
(the file no longer references `AppSegmentedButton`).

`AppSegmentedButton` / `AppSegment` / `AppTabBar` unchanged. No section body files touched.
No pubspec/version change. `request_editor_page.dart` / `response_viewer.dart` untouched
(they appear modified in `git status` from concurrent sibling workers — NOT staged here).

## TDD / baseline

Behavior-preserving refactor; the existing test already specified the contract, so the
baseline was captured GREEN first, the change made, then re-run GREEN (no test edit needed).

Baseline (before change) — `flutter test test/request_debug_page_test.dart`:
```
00:01 +5: All tests passed!
```
(`.omo/evidence/task-7-baseline-test.txt`)

After change — same command, test file UNCHANGED:
```
00:01 +4: 请求调试工作台 切换 4 分区，各分区渲染各自空态
00:02 +5: All tests passed!
```
(`.omo/evidence/task-7-test-green.txt`)

The page test pumps `MaterialApp(home: RequestDebugPage(...))` with NO
`DefaultTabController`; `AppTabBar` owns its own `TabController`, so 4 labels render and
each segment key still switches the body to its matching empty state
(`暂无集合 / 暂无历史 / 暂无环境 / 暂无改写规则`), no exception.

## Analyze

`dart analyze lib/` (`.omo/evidence/task-7-analyze-full.txt`):
- errors: 0
- warnings: 93
- infos: 636
- total: 729  == baseline 93w + 636i (no NEW warning/info)
- occurrences of `request_debug_page.dart` in the report: 0

## Acceptance checklist

- [x] `_buildSectionSwitch` uses `AppTabBar<RequestDebugSection>`; outer horizontal
      `SingleChildScrollView` removed; keys/labels/switch body preserved.
- [x] `flutter test test/request_debug_page_test.dart` passes UNCHANGED (5/5).
- [x] `dart analyze lib/` → 0 errors, no new warning/info (729 == baseline).
- [x] ONE commit staging only `request_debug_page.dart` + this task's evidence. `dist/` never staged.

## Cleanup

No temporary Dart files created. Evidence captures retained under `.omo/evidence/task-7-*.txt`.
