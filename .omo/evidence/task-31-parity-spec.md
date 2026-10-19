# Task 31 — Scene ↔ GStore parity / consistency specification

- Date: 2026-10-19
- Plan: `.omo/plans/scene-to-gstore-parity.md` todo 31 (Wave 5, consistency)
- Status: DONE (spec authoring only; no product/test code touched)
- Scope: the authoritative list of **every** parity dimension between Scene (4.7.3 OSS `/tmp/vtools`, 8.3.7 `/tmp/opencode/scene8/`) and GStore, each with a status, a reason, and a source evidence file.

## Status vocabulary

| Status | Meaning |
|---|---|
| `aligned` | GStore reproduces the Scene value/schema/definition with no observable semantic difference. |
| `approx` | Same intent, different mechanism or a documented approximation; not byte-for-byte Scene. |
| `GStore-only` | Present in GStore, no Scene counterpart (a GStore enhancement or a scene-less field). |
| `semantic deviation` | Same field/name, different meaning or unit from Scene; documented deliberately. |
| `not aligned` | Cannot or will not be aligned; reason recorded. |
| `unverified` | Not verifiable without a real device; labeled as a residual risk. |

**Source evidence files (authoritative per todo):** `task-2-scene-reference.md` (refs/thresholds), `task-3-mode-feasibility.md` (mode feasibility), `task-33-scene-data-schema.md` (battery/charge/FPS schema), `task-14..task-30` (Wave 3/4 outputs), plus `audit-scene8-fidelity.md` and `scene8-comparison.md` (fidelity audit).

---

## 1. Units & labels

### 1.1 Metric units

| # | Dimension | Scene | GStore | Status | Reason | Evidence |
|---|---|---|---|---|---|---|
| U1 | FPS | fps (samples) | fps | aligned | Same quantity and unit. | task-33 §3 (CSV `FPS`); task-14 |
| U2 | Jank / BigJANK | jank, big_jank (count/ratio) | jankPercent / bigJank | aligned | Same modeled quantity. | task-33 §3 (`JANK,BigJANK`) |
| U3 | CPU load | % | % | aligned | Same unit. | task-2 §4.2; task-23 |
| U4 | CPU frequency | MHz (per-cluster, `cpu_frequencies` JSON in `fps_history`) | MHz (per-cluster) | approx | Same unit; GStore samples per-cluster MHz, Scene stores a JSON blob. Model shape differs, values comparable. | task-33 §3; task-27 |
| U5 | GPU load | % | % | aligned | Same unit. | task-33 §3 (`GPU(%)`) |
| U6 | GPU frequency | Scene CSV header labels `GPU(KHz)` | GStore displays MHz | **not aligned** | Header unit (`KHz`) is not traced to a reliable Scene consumption site, and GStore's monitor shows MHz. Exact unit correspondence is unproven, so it is not claimed. | task-33 §3 (`GPU(KHz)`) |
| U7 | DDR frequency | MHz (`ddr_freq`) | not surfaced | **not aligned** | Scene `fps_history` records `ddr_freq`; GStore does not port a DDR-frequency field. | task-33 §3 (`DDR(MHz)`) |
| U8 | Battery capacity | % | % | aligned | Same unit. | task-33 §3 (`Battery(%)`) |
| U9 | Battery temperature | ℃ | ℃ | aligned | Same unit. | task-33 §3 (`Battery(℃)`); task-14/task-15 |
| U10 | Battery current | mA (`battery_io` / `current`) | mA | aligned | Same unit. | task-33 §3 (`Battery(mA)`), §1/§2 |
| U11 | Battery voltage | volt | volt | aligned | Same unit (`voltage` REAL). | task-33 §3 (`Battery(volt)`), §1/§2 |
| U12 | Derived power | `Power(mW)` label, but SQL computes `mA*v` then `/1000`; `power8` uses raw `current*voltage` with no `/1000` | `avgPower` = mean of `voltage_v * current_ma / 1000` (declared W) | **semantic deviation** + `unverified` | Scene is internally inconsistent (label `mW` vs physical `/1000`); no physical unit is hard-coded. See §5.2. | task-33 §Units; task-14; task-15 |
| U13 | RAM use | % | % | aligned | Same unit. | task-2 §4.2; task-23 |
| U14 | viewSize | `surface_view_size` text | logical-pixel string `'<w>x<h>'` | **semantic deviation** | GStore uses `MediaQuery.size`-equivalent logical pixels; Scene stores a surface-view-size string. Choice recorded. See §3.1 and §5.1. | task-14; task-15 |

### 1.2 Labels

| # | Dimension | Scene | GStore | Status | Reason | Evidence |
|---|---|---|---|---|---|---|
| L1 | Four mode labels | 省电 / 均衡 / 性能 / 极速 (`strings.xml:286-289`) | 省电 / 均衡 / 性能 / 极速 (`PerfMode` powersave/balance/performance/fast) | aligned | Identical label set. | task-2 §3; task-24 |
| L2 | 5 feature-hub group labels | 7 groups (场景模式/设备性能/充电耗电/进阶功能/Xposed功能/辅助功能/交流反馈) | 5 groups (场景模式/设备性能/充电耗电/进阶功能/辅助) | approx | 7→5 fold: 4 same-name folds + 辅助 folded; Xposed dropped; 交流反馈 moved to 设置. | task-2 §2 |
| L3 | Mode as a session field | Scene `mode` text = Scene power mode label | GStore `mode` = active profile label (free-form String) | **semantic deviation** | Same field name, different semantics. See §5.3. | task-14; task-15 |
| L4 | `viewSize` label | surface view size | logical view size | **semantic deviation** | Different measurement basis (see U14). | task-15 |
| L5 | Settings/entry labels | Scene settings entries | GStore settings groups | approx | Aligned groups where an equivalent exists (task-13); not exhaustive 1:1. | task-13 |

---

## 2. Thresholds

### 2.1 Statistical ratio thresholds (evidenced)

| # | Threshold | Value | Boundary | Status | Source (file:line) | Evidence |
|---|---|---|---|---|---|---|
| T1 | Fluency (fpsFluencyRatio) | 45 fps | `>= 45` | aligned (evidenced) | `scripts.js:152` | task-2 §4.1/§4.4; task-16; task-23 |
| T2 | High-temp ratio | 46 ℃ | `>= 46` | aligned (evidenced) | `scripts.js:163` | task-2 §4.1/§4.4; task-16; task-23 |

### 2.2 Chart load color-tier thresholds (evidenced)

| # | Threshold | Value | Boundary | Status | Source (file:line) | Evidence |
|---|---|---|---|---|---|---|
| T3 | CPU veryHigh | 85 | `> 85` | aligned (evidenced) | `CpuChartView.kt:172` / `CpuChartBarView.kt:72` | task-2 §4.2/§4.4; task-23 |
| T4 | CPU high | 65 | `> 65` | aligned (evidenced) | `CpuChartView.kt:174` / `CpuChartBarView.kt:74` | task-2 §4.2/§4.4; task-23 |
| T5 | RAM veryHigh | 89 | `> 89` | aligned (evidenced) | `RamChartView.kt:158` / `ZRamStateView.kt:154` | task-2 §4.2/§4.4; task-23 |
| T6 | RAM high | 80 | `> 80` | aligned (evidenced) | `RamChartView.kt:160` / `ZRamStateView.kt:156` | task-2 §4.2/§4.4; task-23 |
| T7 | Battery temp veryHigh | 48 | `>= 48` | aligned (evidenced) | `BatteryView.kt:176` / `FloatMonitorBatteryView.kt:176` | task-2 §4.2/§4.4; task-23 |
| T8 | Battery temp high | 44 | `> 44` | aligned (evidenced) | `BatteryView.kt:178` / `FloatMonitorBatteryView.kt:178` | task-2 §4.2/§4.4; task-23 |
| T9 | Battery temp mid | 41 | `> 41` | aligned (evidenced) | `BatteryView.kt:180` / `FloatMonitorBatteryView.kt:180` | task-2 §4.2/§4.4; task-23 |

All 5 threshold groups required by the plan (FPS 45 / high-temp 46 / CPU 85·65 / RAM 89·80 / temp 48·44·41) are evidenced and were centralized into `lib/core/perf/scene_thresholds.dart`. `not aligned` count for these = 0 (task-23 §2).

### 2.3 Alert thresholds vs color tiers (the distinction, hard requirement)

| # | Dimension | Scene | GStore | Status | Reason | Evidence |
|---|---|---|---|---|---|---|
| T10 | Color-tier thresholds | 5 groups above | `scene_*` constants in `scene_thresholds.dart` | aligned | Adopted verbatim. | task-2 §4.2; task-23 |
| T11 | Out-of-range **alert** config | Scene has no equivalent configurable alert set in the extracted evidence | GStore `perf_alert_settings.dart`: `cpuPercent=80`, `temperatureC=45`, `jankPercent=5`, `minFps=50` | **GStore-only** + **semantic deviation** | Different semantics: color tiers = display coloring; alert settings = user-configurable breach alarms. They MUST NOT be merged. Unit tests assert CPU 85≠80, temp 48/44/41≠45, FPS 45≠50. | task-2 §4.5; task-23 §3 |
| T12 | Color literals | `colors.xml` hex tokens (`#fc8a1b` etc.) | Material theme tokens (no hard-coded hex; `AGENTS.md` rule) | **semantic deviation** | GStore colors come from `Theme.of(context).colorScheme` by design; Scene hex values are not transplanted. Intent (tier→color) preserved. | task-2 §4.3; task-23 §4 |

### 2.4 Process thresholds

| # | Dimension | Scene | GStore | Status | Reason | Evidence |
|---|---|---|---|---|---|---|
| T13 | Process color thresholds | keine evidenced in task-2 | inherited baseline literals (kept as-is) | **not aligned** | task-2 / task-33 evidence no Scene process color thresholds, so nothing could be adopted or centralized. GStore's process thresholds keep their original literals. | task-2 §4.4/§4.5; task-23 §2 |

---

## 3. Data schema

### 3.1 FPS session

| # | Dimension | Scene | GStore | Status | Reason | Evidence |
|---|---|---|---|---|---|---|
| S1 | `sessionId` ↔ `id` | `FpsWatchSession.sessionId` (int) | `FpsSession.id` (String); new getter `sessionId => id` (no new field) | aligned (alias) | JSON writes only `id`; `session_id` accepted as fallback on decode only when `id` absent. Type differs (String vs int) but the mapping is deliberate and documented. | task-14 |
| S2 | `avgPower` | `FpsWatchSession.avgPower`; `fps_history` power = `avg(battery_io*voltage)/1000` | `FpsSession.avgPower` = mean of `voltage_v * current_ma / 1000` (declared W) | **semantic deviation** + `unverified` | GStore-equivalent definition recorded; physical unit unverified (see U12/§5.2). | task-33 §3; task-14; task-15 |
| S3 | `viewSize` | `surface_view_size` text | `MediaQuery.size`-equivalent logical pixels | **semantic deviation** | Choice recorded: `platformDispatcher.views.first` physicalSize/devicePixelRatio. | task-14; task-15 |
| S4 | `mode` | Scene power mode label | free-form `String`, active profile label; empty when unavailable | **semantic deviation** | Independent of `PerfMode`; no enum coupling. | task-14; task-15; task-24 |
| S5 | `temperatures` | NOT a Session field (Scene stores per-sample temp in `fps_history.temperature`) | `FpsSession.temperatures` (List<double>) | **GStore-only** | See §4.1. | task-14; task-15 |
| S6 | avg/min/max fps, samples, source, label/package, startMs/endMs | present | present | aligned | Pre-existing GStore model already carried these. | task-14 |
| S7 | Backward-compatible JSON | n/a | old JSON decodes with defaults, never throws | GStore-only | Tolerant decode (`_string`/`_finiteDouble`/`_finiteValues`). | task-14 |
| S8 | CSV export header | Scene `PerfWatchStore` CSV (`FPS,JANK,...,Power(mW)`) | GStore `buildFpsSessionCsv`: old columns kept, then `mode, view_size, avg_power, fluency_ratio, high_temp_ratio` appended | approx | Scene-parity columns appended; ratios computed via shared helpers; empty session still emits a valid header. Unit label for power not asserted (unverified). | task-17; task-33 §3 |
| S9 | Session persistence | Scene SQLite `fps_watch_log7` (tables `session`, `fps_history`, `perf_statistics`, `threads`) | GStore `shared_preferences` single-key JSON | **semantic deviation** | Mechanism differs (GStore has no SQLite dependency). Concept aligned. | task-33 §3; task-14; `scene8-comparison.md` §C |

### 3.2 battery-history (plan alias → real Scene `power8.records`)

| # | Dimension | Scene | GStore | Status | Reason | Evidence |
|---|---|---|---|---|---|---|
| B1 | Table name/owner | `com.omarea.store.f0`, DB `power8`, table `records` (plan alias `battery-history` does **not** exist in the APK) | `BatteryHistoryStore`, JSON key `battery_history_records` | approx | Schema adopted verbatim; names are the real Scene names, not the plan aliases. | task-33 §Verdict/§1; task-18 |
| B2 | Columns | `time(text pk), session(int), temperature(REAL,-1), status(int,-1), mode(text), current(int,-1), voltage(int/REAL), package(text), screen_on(INTEGER), capacity(INTEGER)` | identical field names, order, JSON keys | aligned | Verbatim DDL adoption; `voltage` modelled `double` (raw operand, no conversion). | task-33 §1; task-18 |
| B3 | Per-app aggregation | `group by package,mode where session=? and status in (3,4) and screen_on=1 and package!=''`, `power=avg(current*voltage)`, avg/min/max temperature, count | `aggregateAppPower` verbatim SQL semantics | aligned (formula) + `unverified` (power unit) | No guessed formula; power unit unverified (U12). | task-33 §1; task-18 |
| B4 | Session power | `avg(current*voltage)` where `screen_on=1 and status in (3,4)` | `aggregateSessionPower` | aligned (formula) + `unverified` (power unit) | Verbatim. | task-33 §1; task-18 |
| B5 | Pruning | keep ≤ 99 sessions; delete `used < {100,300,600}` etc. | keep newest ≤ 99 sessions (`kBatteryHistorySessionCapacity=99`) | aligned (core) | Core rule adopted; GStore's over-complex Scene sub-rules not transplanted for determinism. | task-33 §1; task-18 |
| B6 | Write gate | Scene `PowerStat`: skip when status 2(CHARGING)/5(FULL); sample when screen on; 1s/3s rhythm; 24h rotation | `battery_history_recorder.dart` gate reproduces: reject status 2/5, require screen-on, 1s initial / 3s interval | aligned (cited) | Gate cited from decompiled `PowerStat`; stricter safety: non-finite fields skip the tick rather than persisting sentinels. | task-19 |
| B7 | Lifecycle / background service | Scene keeps a persistent `PowerStat` service + `AlwaysNotification` | app-process `Timer`; no foreground service (no manifest change) | **not aligned** (scope) | Cross-process background sampling is out of scope; documented limitation. Manifest verified byte-identical. | task-19 |
| B8 | Persistence mechanism | SQLite `power8` | `shared_preferences` JSON | **semantic deviation** | GStore convention (no SQLite dependency). | task-18 |
| B9 | Status enum | Android `BATTERY_STATUS_*`; `3=DISCHARGING`, `4=NOT_CHARGING` | `batteryStatusFromLabel` maps Charging→2, Discharging→3, Not charging→4, Full→5, unknown→1 | aligned (standard) | Standard Android mapping; exact Scene enum beyond 3/4 marked `unverified`. | task-33 §Confidence; task-19 |

### 3.3 charge-history (plan alias → real Scene `charge8.records`)

| # | Dimension | Scene | GStore | Status | Reason | Evidence |
|---|---|---|---|---|---|---|
| C1 | Table name/owner | `com.omarea.store.n`, DB `charge8`, table `records` (plan alias `charge_history2` does **not** exist in the APK) | `ChargeHistoryStore`, JSON key `charge_history` | approx | Schema adopted verbatim under the real Scene name. | task-33 §Verdict/§2; task-21 |
| C2 | Columns | `time(text pk), session(int), current(INTEGER), voltage(REAL), capacity(INTEGER), temperature(REAL)` | identical fields/JSON keys (`time,session,current,voltage,capacity,temperature`) | aligned | Verbatim DDL adoption; units mA/V/%/℃. | task-33 §2; task-21 |
| C3 | Sampling gate | Scene `ChargeStat`: `status==2 (CHARGING) && |current|>100`; timer 5s/1s | `passesChargeGate`: charging status AND `|current|>100`; 5s initial / 1s interval | aligned (cited) | Gate cited; status read as string `"Charging"` (sysfs spelling of `BATTERY_STATUS_CHARGING`), documented mapping deviation. | task-33 §2; task-21 |
| C4 | Charge-amount integration | trapezoid/step `sum(current*dt)/3600` | `summarizeChargeSessions` mirrors `n.h()`; derived power `current*voltage/1000` | approx + `unverified` (power unit) | Formula reused; unit unverified (U12). | task-33 §2; task-21 |
| C5 | Pruning | keep ≤ 99 sessions; delete by `capacityRatio` thresholds | keep ≤ 99 sessions, drop smallest `|capacityRatio|` | approx | Scene's raw pruning is buggy/inconsistent; only the core defensible rule adopted for determinism (documented deviation). | task-33 §2; task-21 |
| C6 | Three chart series | `capacity+temperature`, `capacity+current`, `capacity+power` (all `order by time`) | same three series on the charge curve page (x-axis = capacity) | approx | Plan prose said "time-capacity" for the third chart; the adopted series follows task-33 (`capacity+power`), time used for ordering. Power axis unit `unverified`. | task-33 §2; task-22 |
| C7 | Persistence mechanism | SQLite `charge8` | `shared_preferences` JSON | **semantic deviation** | GStore convention. | task-21 |

### 3.4 FPS session store shape (Scene `fps_watch_log7.fps_history`)

| # | Dimension | Scene | GStore | Status | Reason | Evidence |
|---|---|---|---|---|---|---|
| F1 | Battery columns in FPS samples | `capacity`, `temperature`, `battery_io`, `voltage`, `power_mode` | `temperatures` (battery), `avgPower`; capacity/voltage/current sampled via recorder environment | approx | GStore folds per-sample data into session-level `temperatures`/`avgPower`; Scene keeps per-sample rows. | task-33 §3; task-15 |
| F2 | Power SQL | `avg(battery_io*voltage)/1000` | `avgPower` mean of `voltage_v*current_ma/1000` | semantic deviation + `unverified` | Same expression, GStore session-mean; unit unverified. | task-33 §3; task-15 |

---

## 4. GStore-only items (no Scene counterpart)

| # | Item | Status | Reason | Evidence |
|---|---|---|---|---|
| G1 | `FpsSession.temperatures` (List<double>, per-session battery temperatures) | **GStore-only** | Scene keeps per-sample temperature in `fps_history`, not as a Session field; GStore adds it to the session model (branded explicitly non-Scene in the plan). Only non-finite values filtered; negatives kept. | task-14; task-15 |
| G2 | `perf_alert_settings.dart` configurable alerts (cpu80/temp45/jank5/minFps50) | **GStore-only** + semantic deviation | No Scene equivalent in extracted evidence; distinct from color tiers (T11). | task-2 §4.5; task-23 §3 |
| G3 | Three-way FPS UI, refresh auto engine, rich overlay | **GStore-only** | Deliberate GStore enhancements, preserved (not Scene parity items). | `audit-scene8-fidelity.md` §E |
| G4 | `sett` (session battery mAh estimate) | **GStore-only** | Page-local derived display value (trapezoidal integral), not a Scene table field. | `tj 20` (task-20) |
| G5 | GStore SharedPreferences JSON keys (`battery_history_records`, `charge_history`) | **GStore-only** | Mechanism artifact. | task-18; task-21 |
| G6 | AI route/grid entry, applist/discovery routes | **GStore-only** | Scene has no AI tab; GStore shell restructure. | task-5; task-9; task-11; task-12; task-32 |
| G7 | Root-optional gate, `RootStatus`, Shizuku-first capability model | **GStore-only** | GStore privilege model (locked decision 3). | task-30 |

---

## 5. Semantic deviations (same name/field, different meaning or unit)

| # | Item | Scene | GStore | Reason | Evidence |
|---|---|---|---|---|---|
| D1 | `viewSize` | surface view size string | logical pixels `'<w>x<h>'` | Recorder is pure Dart (no BuildContext); recorded equivalent choice. | task-14; task-15 |
| D2 | Power unit | `Power(mW)` label but internally `/1000`-inconsistent | declared W, physical unit `unverified` | Scene incoherent; no physical unit hard-coded. | task-33 §Units; task-14; task-15 |
| D3 | `mode` | Scene power mode label | free-form GStore active-profile label, empty when unavailable | No runtime "effective profile label" concept yet; recorder seam accepts any string. | task-14; task-15 |
| D4 | Color tokens | Scene `colors.xml` hex | Material theme tokens | GStore design-system rule. | task-2 §4.3; task-23 |
| D5 | Merge/precedence for modes | Scene mode scripts apply whole profiles | GStore per-field precedence: explicit non-null knobs win, preset fills unset | Locked decision (plan WS4). | task-26 |
| D6 | cpuset | Scene writes 4 shared masks (`/dev/cpuset/*/cpus`) | GStore writes membership (`/dev/cpuset/<name>/tasks`) | Existing applier semantics; documented. | task-3 §3.3; task-27 |
| D7 | GPU pwrlevel | Scene `gpu_pl_up N` writes `min_pwrlevel` (runtime base) | GStore maps `gpuLevel` → `max_pwrlevel` | Existing applier maps to max; stored raw Scene offset as reference, not claimed equivalent. | task-27 §deviations; task-26 |
| D8 | Charge status read | Scene reads `BatteryManager.getIntProperty==2` | GStore reads sysfs `status` string `"Charging"` | Direct sysfs spelling of the same Android status. | task-21 |
| D9 | Session id source | Scene SQLite auto-increment | GStore launch wall-clock ms (overridable) | No SQLite; unique per app run. | task-19 |

---

## 6. Not aligned / non-alignable items

| # | Item | Status | Reason | Evidence |
|---|---|---|---|---|
| N1 | Global FPS fallback (`measured_fps` sysfs ×3, `fpsgo_status`, `service call SurfaceFlinger 1013`) | **not aligned** (approx used instead) | GStore uses `--timestats` as the global fallback, which is more general but not Scene's exact channel. | `audit-scene8-fidelity.md` §A/§补缺 |
| N2 | Refresh-rate write mechanism | **not aligned** | Scene uses a private `Daemon` + `refresh_rate.txt`; GStore uses `settings put system min/peak_refresh_rate` (may not take effect on some ROMs). Intent similar, mechanism different. | `audit-scene8-fidelity.md` §B; `scene8-comparison.md` §2 |
| N3 | MIUI thermal root remount + direct write to `/data/vendor/thermal/config` | **not aligned** | Scene is root remount direct write; GStore is a deliberately safer whitelist backup/restore (no remount). Root-only direct write exists but is opt-in via the root gate, never the default. | `audit-scene8-fidelity.md` §D; task-30 |
| N4 | Destructive MIUI debloat (`pm uninstall`/`pm disable`/`killall com.miui.daemon`, property spoof, `setprop vtools.thermal.disguise`) | **not aligned** (unsupported) | Guardrail: no destructive/root remount ops. | task-3 §2 row 7/§3.4 |
| N5 | Xposed group (应用设置/全局设置) | **not aligned** (dropped) | GStore has no Xposed module; no equivalent route (would be a dead entry). | task-2 §2 |
| N6 | 交流反馈 group (QQ 群/分享) | **not aligned** (moved out of grid) | Non-functional group; relocated to the 设置 tab. | task-2 §2 |
| N7 | Per-app **refresh-rate** auto engine | **not aligned** (not built) | Listed as follow-up in the fidelity audit; out of parity plan scope. | `scene8-comparison.md` §2/§5 |
| N8 | GPU freq unit (`GPU(KHz)`) and DDR freq field | **not aligned** | See U6/U7. | task-33 §3 |
| N9 | Scene history data migration | **not aligned** (out of scope) | Plan guardrail: no migration wizard (root-only private data). | plan Scope/guardrails |
| N10 | `battery-history` / `charge_history2` literal plan names | **not aligned** (names) | Those literal strings do not exist in the APK (0 hits); the real names are `power8.records` / `charge8.records`. | task-33 §Verdict |
| N11 | Battery background sampling as a foreground service | **not aligned** (scope) | GStore samples only while the Flutter process is alive; no manifest change. | task-19 §decision/B7 |

---

## 7. WS4 subset caveat (modes)

| # | Item | Status | Reason | Evidence |
|---|---|---|---|---|
| W1 | Applied action set | subset (`cpu`, `gpu`, `cpuset`, `thermal` only) | Only `shizuku-writable` knobs are applied; `kShizukuWritableModeActions` = exactly those 4. | task-3 §6/§7; task-26 |
| W2 | Root-only / unsupported Scene mode actions | logged + skipped, never written | `kSkippedRootOnlyModeActions` covers sched_config, sched_boost, stune_top_app, set_ctl, core_ctl, msm_performance, cpu_boost, hispeed, sched_limit, cpu_pl, core_online, cpuctl, devfreq_bw, cgroup_procs, taskset, renice, disable_migt, thermal_disguise, pm_disable, miuibooster. | task-3 §3/§7; task-26 |
| W3 | Full Scene equivalence | **not claimed** | WS4 is a subset; the plan requires not claiming completeness. | task-3 §7; plan success criteria |
| W4 | Runtime authority | `PerfCapabilityProbe` (fail-closed) | Static reachable set is a design assumption only; probe is the authoritative gate; if no writable category, mode UI is disabled with a visible reason. | task-3 §6; task-29 |
| W5 | Target SoC | fallback / no-op default | Owner did not provide a target SoC; lahaina/kona tables are reference-only, selected only by runtime `ro.board.platform`; unknown → safe fallback. | task-3 §5; task-27 |
| W6 | Variant rule | user/profile choice (default conservative) | active vs conservative is a user choice, never auto-inferred from SoC; both bake only shizuku-writable knobs. | task-3 §4; task-27 |
| W7 | Per-field precedence | explicit non-null knobs win; preset fills unset | `mergePerfModePreset`; CPU per-cluster/per-field, GPU/cpuset/thermal independent; identity preserved. | task-26 |
| W8 | Auto-switch lifecycle | foreground + screen events via existing engine | `onScreenState` sleep/resume + existing foreground reconcile; no new engine/store/page. | task-28 |
| W9 | Root optional | root-only actions gated | `RootStatus`/`RootCapabilityGate`; Shizuku primary; root-only items hidden/disabled without root. | task-30 |

---

## 8. Intentional UI/behavior differences

| # | Item | Status | Reason | Evidence |
|---|---|---|---|---|
| I1 | Applist empty-state 「我的频道」button removed | intentional difference | It pointed at the removed `mine` tab; removed rather than left as a dead link. Recorded for this todo. | task-11 |
| I2 | 「浏览发现页」/「导入示例应用」now push `AppRoute.discovery` | intentional difference | Discovery moved from a tab to a route. | task-11 |
| I3 | ApplistPage is a pushable page (own Scaffold, single) | intentional difference | Shell changed to 3 tabs; page is no longer tab-embedded. | task-11 |
| I4 | AI as a route + grid entry (no AI tab) | intentional difference | Shell restructure; no AI-tab restoration. | task-5; task-32 |
| I5 | 3-tab shell (功能/首页/设置) + feature grid | approx | Scene-classic shell; `sourceIndex` removed after its readers were gone. | task-4; task-5; task-32 |
| I6 | Dashboard 4-mode buttons: quick switch over existing per-app store | approx | GStore models modes per-app; the "quick mode" applies the chosen mode to all existing profiles (no synthetic global config). | task-7; task-29 |

---

## 9. Unverified / device-dependent items

Everything below is **unverified** without a real device (residual risk; see `.omo/evidence/device-qa-scene-parity.md`, NOT executed).

| # | Item | Why unverified | Evidence |
|---|---|---|---|
| X1 | Physical power unit (mA×V→mW/W) | Scene internally inconsistent. | task-33 §Units; task-14; task-15 |
| X2 | Shizuku writability of any knob on a real device | Static reachable set is a design assumption; `PerfCapabilityProbe` decides at runtime. | task-3 §6 |
| X3 | Mode apply/rollback behavior under real Shizuku | No device; engine behavior verified only with fakes. | task-26; task-28; task-29 |
| X4 | Root-gated MIUI thermal direct write | No device; unit-tested via injectable runner only. | task-30 |
| X5 | Charge/curve and battery-stats visuals | No device; widget tests only. | task-20; task-22 |
| X6 | `--latency` column selection and `settings put system` refresh behavior | Needs device; flagged in the fidelity audit. | `audit-scene8-fidelity.md` §风险 |
| X7 | `status` enum semantics beyond 3/4 | Only standard Android mapping is provable. | task-33 §Confidence |

---

## 10. Summary lists

### 10.1 `not aligned`

U6 (GPU freq unit), U7 (DDR freq), T13 (process thresholds), B7 (background service), N1 (global FPS fallback channel), N2 (refresh-rate write mechanism), N3 (MIUI thermal root remount), N4 (destructive debloat), N5 (Xposed group), N6 (交流反馈 group placement), N7 (per-app refresh engine), N8 (GPU/DDR units), N9 (Scene data migration), N10 (the literal plan aliases `battery-history`/`charge_history2`), N11 (foreground-service battery sampling).

### 10.2 `GStore-only`

G1 (`FpsSession.temperatures`), G2 (alert settings), G3 (three-way FPS / refresh auto / rich overlay), G4 (session mAh estimate), G5 (SharedPreferences keys), G6 (AI route/grid + applist/discovery routes), G7 (root gate / Shizuku-first model). Plus the mechanism choices in S7.

### 10.3 `semantic deviation`

U12 (power), U14/L4 (viewSize), L3 (mode field), T11 (alerts vs color tiers), T12/D4 (color tokens), S2 (avgPower), S4 (mode), S9 (FPS persistence mechanism), B8 (battery persistence), C7 (charge persistence), F2 (power SQL), D2 (power unit), D5 (mode merge precedence), D6 (cpuset), D7 (GPU pwrlevel), D8 (charge status read), D9 (session id source).

### 10.4 `aligned` / evidenced

All of §1.2 L1; U1/U2/U3/U5/U8/U9/U10/U11/U13; T1..T9 (all evidenced); B2/B3/B4/B6/B9; C2/C3; S1/S6.

---

## Acceptance self-check (todo 31)

- [x] One row/entry per parity dimension with status + reason (§§1–9).
- [x] Explicit `not aligned` / `GStore-only` / `semantic deviation` lists (§10.1–10.3).
- [x] Each dimension cites its source evidence file (task-2/task-3/task-33/task-14..30 + audit docs).
- [x] `temperatures` marked GStore-only (§4 G1); `sessionId↔id` (§3.1 S1); `avgPower`/`viewSize` definitions (§3.1 S2/S3, §5 D1/D2); `mode` semantic deviation (§5 D3); process thresholds `not aligned` (§2.4 T13); applist 「我的频道」removal (§8 I1); WS4 subset caveat (§7).
- [x] Every unverified/device-dependent item marked (§9 X1–X7).
- [x] No product/test code touched (docs only).
