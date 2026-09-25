# Task 17 — full-screen response body zoom with aligned line-number gutter

Plan: `.omo/plans/request-debug-ui-ux.md` todo 17.
User request: 「独立响应信息页面，能不能指出内容缩放呢，缩放后记得行号也要对齐呢」
(= On the standalone full-screen response body page, add content zoom; keep the
line-number gutter aligned with the lines after zooming.)

## Change summary

`lib/page/request_debug/response_viewer.dart`

- `_ResponseBodyFullScreen` converted `StatelessWidget` → `StatefulWidget` holding
  `double _scale = 1.0`. AppBar now carries four controls:
  - `response-fullscreen-zoom-out` (`Icons.zoom_out`)
  - `response-fullscreen-zoom-level` (label `100%` / `125%` / …)
  - `response-fullscreen-zoom-in` (`Icons.zoom_in`)
  - `response-fullscreen-zoom-reset` (`Icons.restart_alt`)
  - Clamped to **0.75 – 2.0 in 0.25 steps**; zoom-in/out `onPressed` is `null` at
    the bounds, so overshoot is ignored with no exception.
- `_ResponseBodyPane` gained `double scale = 1.0` (inline Body / inline Raw never
  pass it → stay 1.0 with **no** zoom UI).
- One scaled source for the whole body:
  - `_contentFontSize = (AppTypography.code.fontSize ?? sizeSM) * scale`
  - `_contentLineHeight = base * (AppTypography.code.height ?? heightNormal) * scale`
  - `_scaledCodeStyle = AppTypography.code.copyWith(fontSize: _contentFontSize, height: …)`
  - `_gutterLineHeight = _contentLineHeight.roundToDouble()`
- `_scaledCodeStyle` is now used by: the JSON content `Text.rich`, **every**
  `_jsonTokenStyle` token variant, the chunked/plain `SelectableText`, and the
  gutter number `Text`.
- The content `Text.rich` now has key `Key('${keyPrefix}-json')`
  (`response-fullscreen-json` / `response-body-json`).
- Replaced the fixed `const lineHeight = sizeSM * heightNormal` with
  `_gutterLineHeight`, rounded to match how the text engine lays out the line box.
- No new dependency; no `showDialog` / hand-written sheet (plain route, unchanged);
  all pre-existing full-screen keys preserved.

### Why `roundToDouble()` (行号对齐) is required

Verified empirically (throwaway probe, deleted) that Flutter's line box for a
`TextStyle` with `height` is `round(fontSize × height)` and **not** the raw float,
independent of `fontFamily`:

| fontSize | fontSize×1.5 | measured per-line |
| --- | --- | --- |
| 14.0 | 21.00 | 21 |
| 14.3 | 21.45 | 21 |
| 14.7 | 22.05 | 22 |
| 17.5 | 26.25 | 26 |
| 21.0 | 31.50 | 32 |
| 24.5 | 36.75 | 37 |

At scale 1.25 the JSON content line box is 26 px, so the gutter must also use 26
(not 26.25) or the gutter drifts 0.25 px per line. Hence the gutter uses the
rounded value while the content font size is the exact `14 × scale`; both derive
from the same scaled source, so they stay aligned at 1.0 / 1.25 / 1.5 / 1.75 / 2.0.

`test/request_debug_response_test.dart` — new group `全屏缩放 · 行号对齐`:

1. zoom-in: font `14 → 17.5`, gutter grows, and `getSize(gutter).height ==
   getSize(jsonContent).height` at 1.0 and 1.25; at 2.0 the exact same factor
   (2×) is asserted for both (integer line box removes rounding noise).
2. zoom-out shrinks; `-level` label tracks `100% / 125% / 150% / 75%`;
   `-reset` returns to `100%` and the base font.
3. clamp at `200%` / `75%` after repeated taps, `takeException() == null`.
4. chunked `text/plain` also scales `14 → 17.5`.
5. inline Body renders **no** zoom keys and stays at `AppTypography.sizeSM`.

## TDD evidence

- RED: `flutter test test/request_debug_response_test.dart` → `+28 -5` (the 5 new
  cases fail: zoom keys + `-json` key absent). Log: `.omo/evidence/task-17-red.txt`.
- GREEN: `flutter test test/request_debug_response_test.dart
  test/request_debug_editor_test.dart` → `+50: All tests passed!`.
  Log: `.omo/evidence/task-17-green.txt`.
- Static: `dart analyze lib/` → 729 = 0 errors / 93 warnings / 636 infos == baseline,
  **0** entries for `response_viewer.dart`; single file `dart analyze
  lib/page/request_debug/response_viewer.dart` → `No issues found!`.
  Log: `.omo/evidence/task-17-analyze.txt`.

## Acceptance mapping

| Criterion | Test |
| --- | --- |
| zoom-in raises JSON font size + gutter line height, same factor | `放大 → …` (exact 2× at 2.0; 1.25 growth + aligned) |
| `getSize(gutter).height == getSize(jsonContent).height` at 1.0 and after zoom | `放大 → …` |
| zoom-out shrinks; `-level` label reflects scale | `缩小 / 级别标签 / 重置回 1.0` |
| `-reset` returns to 1.0 | `缩小 / 级别标签 / 重置回 1.0` |
| clamp at min/max, no exception | `在上下限 0.75 / 2.0 处钳制且不抛异常` |
| chunked plain text also scales | `分块纯文本同样按缩放因子变大` |
| inline Body: no zoom controls, default size | `行内 Body 无缩放控件且保持默认字号` |
| `takeException() == null` | every case |

## Manual QA

`flutter test test/request_debug_response_test.dart test/request_debug_editor_test.dart`
(50/50) opens the opaque full-screen route, taps zoom in/out/reset, and asserts the
gutter and JSON content stay equal-height at 1.0, 1.25 and 2.0 with no exception;
the inline Body keeps rendering at the default size with no zoom affordances. No
device run required for widget-level behavior.

## Files / commit

- `lib/page/request_debug/response_viewer.dart`
- `test/request_debug_response_test.dart`
- `.omo/evidence/task-17-request-debug-ui-ux.md` (+ red/green/analyze logs)

`dist/` untouched; `rust/**` untouched; `pubspec.yaml` unchanged.

## Follow-up fix — review finding N4 (gutter number width not scaled)

**Finding:** the gutter line-number box width stayed `AppSpacing.xs + digits *
sizeXS` while the number font scaled, so at zoom ≥ 1.25× a multi-digit row count
(e.g. a 50-line JSON) clipped / crowded the collapse-chevron slot.

**Fix** (`response_viewer.dart`, `_buildJsonGutter`):
- `numberWidth = (AppSpacing.xs + '$lineCount'.length * AppTypography.sizeXS) *
  widget.scale` — same `widget.scale` source as the font; nothing hardcoded.
- added stable key `Key('${keyPrefix}-num-$i')` to the number `SizedBox`
  (`response-fullscreen-num-0`, …); existing `-gutter` key untouched.

**Test** (appended to `全屏缩放 · 行号对齐`): with a ≥10-line JSON (14 pretty
lines), open the full-screen body, measure `response-fullscreen-num-0` at 1.0×
and after zooming to 2.0×; assert `widthMax / width0 ≈ 2.0` and
`takeException() == null` (no overflow/clipping).

**Raw output**
- RED (`.omo/evidence/task-17-n4-red.txt`): `放大器...` case fails — the keyed
  number box didn't exist yet.
- GREEN (`flutter test test/request_debug_response_test.dart
  test/request_debug_editor_test.dart`): `+51: All tests passed!`
  (`.omo/evidence/task-17-n4-green.txt`).
- `dart analyze lib/` = 729 = 0 errors / 93 warnings / 636 infos == baseline, 0
  entries for `response_viewer.dart` (`.omo/evidence/task-17-n4-analyze.txt`).
