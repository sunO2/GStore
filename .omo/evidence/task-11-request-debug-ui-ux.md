# Task 11 — response JSON readability with size cap + full-body search

- Plan: `.omo/plans/request-debug-ui-ux.md` todo 11
- HEAD before: `dfdc11d`
- Commit message: `feat(request-debug): readable highlighted JSON response viewer with size cap`
- Changed files: `lib/page/request_debug/response_viewer.dart`, `test/request_debug_response_test.dart`

## What changed

- In-house JSON tokenizer (`tokenizeJsonLine` → `JsonToken` / `JsonTokenKind`: key/string/number/keyword/punctuation/plain) + fold-region scanner (`jsonFoldRegions` → `JsonFoldRegion{id,openLine,closeLine}`). Both pure, total, never throw.
- `Text.rich` highlight tree keyed `response-body-tree`: line-number gutter (`response-body-gutter`), horizontal scroll (`SingleChildScrollView` horizontal) with `softWrap:false` (no wrap), vertical scroll, collapsible containers (`response-body-collapse-<id>`, id == opening line index) hiding the descendant lines of the folded subtree.
- In-body search bar keyed `response-body-search` with input `response-body-search-input` (JSON tree AND chunked plain path). Search runs over the **full** text (`_searchSourceText`), and for the chunked path expands `_visibleChars` to include the matched offset.
- 256 KB cap: `ResponseViewer.maxJsonHighlightChars = 256 * 1024`. JSON bodies over the cap (and all non-JSON bodies) use the existing chunked plain rendering (`response-body-text` / `response-body-more`). Over-cap JSON is shown raw (no expensive pretty pass).
- XML keeps `prettyXml`; no dependency added; theme tokens only (`.withValues(alpha:)`).
- Header/cookie tables remain `Expanded`-based and produce no overflow at 360dp.

## TDD

1. RED (test rewritten first): `flutter test test/request_debug_response_test.dart`
   - `Compilation failed ... Method not found: 'jsonFoldRegions' / 'tokenizeJsonLine' / 'JsonTokenKind'`, `+0 -1`.
2. Intermediate failures fixed in the **tests** (wrong expectations authored by me, not product bugs):
   - tokenizer sample line had no string value → added `"value"`.
   - `jsonFoldRegions('{"a":{},"b":[]}')` correctly returns 1 region (the root object); empty inline containers add none.
3. GREEN: `flutter test test/request_debug_response_test.dart` → `00:05 +24: All tests passed!`

## Acceptance coverage (all in `test/request_debug_response_test.dart`)

- multi-type JSON → `find.byType(RichText)` under tree + `_treeTokenColors().length > 1` (distinct token styles).
- `response-body-gutter` present.
- `text/plain` > `chunkChars`: marker near tail not in visible text before search; typed into `response-body-search-input`; marker becomes rendered and visible length > `chunkChars` (no private `_visibleChars` reference).
- tapping `response-body-collapse-<id>` removes that subtree's marker text.
- `bodyText.length > 256*1024` JSON → `response-body-more` present, tree/gutter absent, `takeException() == null`.
- headers/cookies at 360x640 → `takeException() == null`.
- malformed JSON → plain fallback, no exception.
- Preserved: `response-body-text`, `response-body-more`, plus existing 16 behaviors.
- Regression: `flutter test test/request_debug_editor_test.dart` → `12: All tests passed!`

## Static gate

- `dart analyze lib/` after fix → `729 issues found` = baseline (0 errors / 93 warnings / 636 infos). No new warning/info.
- Initially one NEW info (`prefer_const_declarations` at gutter `lineHeight`) was fixed to `const`.

## Risks / notes

- The JSON tree renders all visible lines eagerly (bounded by the 256 KB cap) instead of a lazy viewport, because a shared horizontal scroll across all rows needs a single horizontally-unbounded child. This is the explicit trade-off of the cap.
- `_searchSourceText` uses the full displayed text; for `text/plain` this is exactly `bodyText`, satisfying the full-body search requirement.
