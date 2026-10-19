# Device QA checklist — Scene ↔ GStore parity

- Date: 2026-10-19
- Plan: `.omo/plans/scene-to-gstore-parity.md` (final verification item F4)
- Companion spec: `.omo/evidence/task-31-parity-spec.md`
- **STATUS: NOT EXECUTED.** No Android device / emulator was available in this environment. Every item below is therefore **UNVERIFIED** and is a residual risk until run on a real device (and ideally a Scene install for side-by-side comparison).

> Do not read any unchecked box as a pass. Nothing here was run.

## 0. Environment required (not met)

| Requirement | Required | Available | Notes |
|---|---|---|---|
| Android device (or emulator with sysfs + Shizuku) | yes | **no** | Host is Linux, no adb device. |
| Shizuku installed + authorized (ADB or root) | yes | **no** | Required for the capability probe and mode application. |
| A Scene 8.3.7 install for side-by-side | optional | **no** | For visual/behavioral diff. |
| Root (optional) | optional | **no** | Only for the root-gated MIUI thermal direct-write item. |

## 1. Shell & navigation (Scene classic 3-tab)

- [ ] Three bottom tabs render with labels 功能 / 首页 / 设置 (task-5, task-8).
- [ ] Tab switching preserves per-tab scroll/state (task-5).
- [ ] Feature hub shows 5 groups with the 7→5 mapping (task-6, task-10); no dead route.
- [ ] AI grid item is hidden when `agent_tools` is disabled, visible when enabled (task-6).
- [ ] AI opens as a route with a back affordance (no AI tab) (task-32).
- [ ] ApplistPage and DiscoveryPage push/pop cleanly; exactly one Scaffold (task-11, task-12).
- [ ] Applist empty state shows 2 add paths, no 「我的频道」button (task-11).
- [ ] Settings tab shows the Scene-aligned groups without crashing on missing targets (task-8, task-13).

## 2. Dashboard (Scene-style)

- [ ] RAM / SWAP / SwapCached / Buffers / Dirty cards show live values (task-7).
- [ ] GPU / CPU cards and per-core list render live data (task-7).
- [ ] Battery / temperature card colors follow the centralized tiers (48/44/41) (task-7, task-23).
- [ ] CPU / RAM load colors follow 85/65 and 89/80 tiers (task-23).
- [ ] Four mode quick buttons: disabled with a visible reason when no writable capability, enabled and wired otherwise (task-7 placeholder → task-29 wiring).

## 3. FPS session data & analysis

- [ ] A recorded session shows 流畅度 (≥45), 高温占比 (≥46), 功耗, 模式, 视图 (task-16, task-17).
- [ ] CSV export contains the appended scene-parity columns and ratios match the UI (task-17).
- [ ] `sessionId` equals the session `id` (task-14).
- [ ] `temperatures` populate from battery/temperature sampling; negatives kept, NaN/Inf dropped (task-15).
- [ ] `avgPower` populates only from ticks with finite voltage+current (task-15).
- [ ] `viewSize` matches the device logical size string (task-15).
- [ ] 30-minute auto-stop and 1s sampling behave as specified (task-15).

## 4. Battery history / stats

- [ ] Recorder writes rows only for screen-on, non-charging/non-full status (task-19).
- [ ] Battery stats page aggregates by time and by app (mAh / duration / temperature) (task-20).
- [ ] Capacity trim keeps at most 99 sessions (task-18).
- [ ] Clear action confirms and empties the store (task-20).
- [ ] No foreground service is required and sampling survives normal backgrounding as designed (task-19 limitation).

## 5. Charge history / curves

- [ ] Recorder samples only while status is Charging and |current| > 100 mA (task-21).
- [ ] Charge curve shows three series (current-capacity, temperature-capacity, power-capacity) (task-22).
- [ ] Session selection updates the capacity range (task-22).
- [ ] Capacity-ratio pruning keeps at most 99 sessions (task-21).

## 6. Scene modes (WS4 subset)

- [ ] `PerfCapabilityProbe` reports at least one writable category on a real device; otherwise the mode UI is disabled with a reason (task-29).
- [ ] Applying a mode writes only shizuku-writable knobs (cpu/gpu/cpuset/thermal); root-only/unsupported actions are logged and skipped, never written (task-3, task-26).
- [ ] Per-field precedence: explicit non-null knobs override the preset; unset fields are filled by the preset (task-26).
- [ ] Unknown SoC uses the safe fallback preset (task-27).
- [ ] Foreground change applies the app's mode; screen-off sleeps and screen-on resumes (task-28).
- [ ] Partial failure rolls back to the prior state (no half-applied profile) (task-26, task-28).
- [ ] Dashboard quick mode and the page selector both apply to existing per-app profiles (task-29).

## 7. Root-optional gate

- [ ] Without root: root-only items are hidden/disabled with an explicit reason; Shizuku path unchanged (task-30).
- [ ] With root: the MIUI thermal direct-write becomes available only after explicit confirmation and reads back consistently (task-30).
- [ ] No root remount / direct write happens by default (task-30).

## 8. Visual fidelity vs Scene

- [ ] Side-by-side shell layout, group labels, and dashboard cards match Scene's classic look (task-2 §2/§3).
- [ ] Color tiers reproduce the intended Scene tier semantics using GStore theme tokens (task-2 §4.3, task-23).
- [ ] No CJK label clipping / theme regressions in light and dark modes.
- [ ] Push/pop gesture back works on applist/discovery/agent/charge-curve/battery-stats.

## 9. Unverified items carried from the parity spec

Every item in `.omo/evidence/task-31-parity-spec.md` §9 (X1..X7) is covered above and remains UNVERIFIED:
- X1 power physical unit, X2 runtime Shizuku writability, X3 mode apply/rollback, X4 root direct write,
- X5 charge/battery visuals, X6 `--latency` column + `settings put system` behavior, X7 status enum beyond 3/4.

## Outcome

**NOT EXECUTED.** No device was present. All boxes remain unchecked by design. Parity is behavioral/visual and is therefore an explicit residual risk until this checklist is run on a real device; the static/spec/unit evidence in todos 1..33 and the task-31 parity spec is the only parity evidence currently available.
