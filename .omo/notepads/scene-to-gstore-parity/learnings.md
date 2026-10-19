# scene-to-gstore-parity — Learnings

（append-only；由各 todo 追加）

## todo 2 — Scene 参考提取（2026-10-19）
- 7 组来自 `fragment_nav.xml`：场景模式(:18)/设备性能(:108)/充电耗电(:151)/进阶功能(:178)/Xposed功能(:234)/辅助功能(:261)/交流反馈(:288)。**仅第 1 组标题是字符串资源，其余 6 组硬编码中文**。
- 7→5：4 组同名折叠 + 辅助功能→辅助；**Xposed功能整组丢弃**（`FragmentNav.kt:280-291` 均 `xposedCheck{}`+Scene 私有 Xposed 活动，GStore 无等价；`routers.dart` 无 xposed 路由）；**交流反馈整组移出网格→设置 tab**（QQ群/分享 Intent，非功能组）。
- 条目级重排：`nav_battery_stats` 耗电统计 场景模式→充电耗电；`nav_cpu_modes` 性能配置 场景模式→设备性能。
- 仪表盘来自 `fragment_home.xml`：RAM/SWAP、SwapCached/Buffers/Dirty、GPU、CPU、逐核(4列210dp)、电池/温度、设备信息、`home_message`、四档按钮 `powermode_toggles`（省电/均衡/性能/极速 = `strings.xml:286-289`）。
- 阈值全部取证：FPS≥45 `scripts.js:152`；高温≥46 `scripts.js:163`；CPU 85/65 `CpuChartView.kt:172,174`+`CpuChartBarView.kt:72,74`；RAM 89/80 `RamChartView.kt:158,160`+`ZRamStateView.kt:154,156`；温度 48/44/41 `BatteryView.kt:176,178,180`+`FloatMonitorBatteryView.kt:176,178,180`。色值 `colors.xml:21-25`，最高温档内联 `#FF0F00`（无令牌）。
- 坑：GStore 已有 `perf_alert_settings.dart`（cpu80/temp45/jank5/minFps50）是**告警**阈值，与 Scene **颜色档位**语义不同，todo 23 集中化勿混。
- 证据：`.omo/evidence/task-2-scene-reference.md`。
# scene-to-gstore-parity — Learnings (append-only; never overwrite)

## Seed / inherited context
- Plan: `.omo/plans/scene-to-gstore-parity.md` (33 todos + F1–F4). Scene OSS reference = `/tmp/vtools` (package 4.7.3); Scene 8.3.7 evidence = `/tmp/opencode/scene8/`.
- Privilege model (locked): **Shizuku-first (shell uid 2000), root optional**; `PerfCapabilityProbe` is the runtime authority; no root remount direct-write as default.
- WS4 reuses the **existing** `lib/core/perf/perf_profile*` (no second store/engine/page); `perf_mode_profiles.dart` allowed only as a constants table.
- Prior perf work: `.omo/plans/scene-perf-reverse-gstore.md` — `perf.tunables` (24 methods), `perf.sysfs.read`, `perf.foreground`, `PrivilegedShell`, `PerfControlActions`, baseline commit `b1771f6`.

## Todo 3 — mode feasibility spike (design gate) — 2026-10-19
- Artifact: `.omo/evidence/task-3-mode-feasibility.md`.
- **Read-only**: no product/test code touched; no device present (all verdicts are static design assumptions).
- Sources: `powercfg/lahaina/*.sh`, `powercfg/kona/*.sh`; GStore `privileged_shell.dart` / `perf_capability_probe.dart` / `perf_profile.dart` / `control_{cpu,gpu,cpuset,thermal}.dart` / `perf_profile_auto_engine.dart` / `perf_control_actions.dart`.

### Variant rule (from `CpuConfigInstaller.kt`)
- Two **style variants** per SoC dir: `active.sh` (aggressive) vs `conservative.sh` (mild); chosen by a **user choice** in Scene's perf-config UI (`installOfficialConfig(active:Boolean)` → `GLOBAL_SPF_PROFILE_SOURCE = SOURCE_SCENE_ACTIVE|SOURCE_SCENE_CONSERVATIVE`), NOT by SoC. SoC dir = `powercfg/<ro.board.platform>` (lahaina=SD888, kona=SD865).
- lahaina/kona have **no `active-base.sh`/`conservative-base.sh`** → both variants share `powercfg-base.sh`.
- Delta: active = higher CPU maxima, `gpu_pl_up 1`, `sched_boost 1 1`, `stune_top_app 1 50`, `start miuibooster`; conservative = lower, `gpu_pl_up 0`, `sched_boost 1 0`, `stune 0`, `stop miuibooster`.
- **Default = conservative** (safer).

### Target SoC
- **Owner did NOT provide a target SoC** → explicit **`fallback/no-op`** decision: todo 27 ships a safe fallback preset; any SoC-specific lahaina/kona table is reference-only, selected only by runtime `ro.board.platform`; unknown platform → fallback.

### Static reachable set (DESIGN ASSUMPTION; runtime probe is authoritative)
Only 7 knob classes are expressible by the existing applier: CPU governor + min/max freq per cluster; GPU min/max freq + min/max pwrlevel + governor; cpuset masks/membership (`/dev/cpuset/*/{cpus,mems,tasks}`); thermal `thermal_zone*/mode`. **Non-empty → no WS4 descope.**
- Mapped verdicts: `gpu_pl_up`/`gpu_pl_down`/`set_gpu_pl`/`set_gpu_max_freq` = **shizuku-writable**; `cpuset` masks = shizuku-writable (membership via `/dev/cpuset/*/tasks`, NOT `cgroup.procs`).
- **root-only** (outside allowlist; uid 0): `sched_config`, `sched_boost`, `stune_top_app`, `set_ctl`/`ctl_on`/`ctl_off` (core_ctl), `msm_performance` (`set_cpu_freq`'s module-param line), `*/schedutil/*` (`set_hispeed_freq`/`sched_limit`/`set_cpu_pl`), `cpu_boost`, per-cpu `online`, devfreq-BW (`bw_min/max/down/max_always`), `cgroup.procs`, `taskset` (game/per-app affinity), `renice`, `disable_migt`/`lock_value`, `def_pwrlevel` (kona), `thermal_disguise` node.
- **unsupported** (destructive / Xiaomi-only / deliberately excluded): `pm disable` (+ `pm uninstall`/`install-existing`/`clear`, `killall -9 com.miui.daemon`), `stop/start miuibooster`, `thermal_disguise`'s `pm` side-effects, generic `set_value` (arbitrary-path write), dispatch helpers (`adjustment_by_top_app`, `watch_app`).
- **Critical**: WS4 applies only this subset — must NOT claim Scene equivalence. The whole Scene sched/stune/cpuctl/core_ctl/msm_performance/cpu_boost/BW layer is **not** reachable via Shizuku.

### Gotchas for todos 26/27/29
- The existing applier (`perf_profile_auto_engine.dart`) currently writes only GPU `max_pwrlevel` (via `gpuLevel`); min pwrlevel/min freq exist in `GpuControlAction` but are not wired. Mode presets must map onto the existing knobs.
- `conservative` governor only usable if it appears in `availableGovernors` from `perf.tunables` (else `invalid_arg`), so `conservative_mode`'s governor line is only conditionally shizuku-writable.

---

## Todo 33 — Scene 8 battery/charge schema (extracted, REA-assisted)
- **Result: extractable.** The literal names `battery-history` / `charge_history2` are **NOT** in the APK (0 hits). Real owners:
  - `com.omarea.store.f0` → DB **`power8`**, table **`records(time,session,temperature,status,mode,current,voltage,package,screen_on,capacity)`** — per-app battery/power history (plan alias `battery-history`). Power = `avg(current * voltage)`; filter `screen_on=1 AND status in (3,4)` (DISCHARGING/NOT_CHARGING); group by `package,mode`; prune ≤99 sessions.
  - `com.omarea.store.n` → DB **`charge8`**, table **`records(time,session,current,voltage,capacity,temperature)`** — charge curve (plan alias `charge_history2`). 3 charts = capacity+temperature / capacity+current / capacity+**power** (`current*voltage/1000`). Legacy `min(time),max(time),(avg(current)*avg(voltage)*count(current)/3600)`.
  - `com.omarea.store.PerfWatchStore` → DB **`fps_watch_log7`** v18, tables `session` / `fps_history` / `perf_statistics` / `threads`. **`FpsWatchStore` (earlier-audit name) does NOT exist.** `fps_history` carries battery columns `capacity`, `temperature`, `battery_io(mA)`, `voltage(volt, default 3.85)`; power = `battery_io*voltage/1000`.
- **Units (Scene CSV header, `PerfWatchStore.txt:694`)**: `Battery(%)`, `Battery(℃)`, `Battery(mA)`, `Battery(volt)`, `Power(mW)`. **Power unit is internally inconsistent** (header says mW but formula `/1000` with volt-scale default) → mark `unverified`.
- Evidence: `.omo/evidence/task-33-scene-data-schema.md`; raw decompiled stores `/tmp/opencode/scene8/t33_src/`.
- **For todos 18/21**: adopt the `power8.records` / `charge8.records` schemas verbatim (not the aliased names); no guessed formulas; only the power physical unit stays `unverified`.

## Todo 1 — 回归基线 + 工作树卫生（2026-10-19）
- 既有 scene8/perf 脏改动先 commit 为**隔离基线** `a3ab6487f390c0e9d52db7002cdfe1736e7ae960`（`chore(perf): checkpoint scene8 parity prerequisites`，63 files，排除 `dist/`）；提交后 `git status --porcelain` == `?? dist/`，parity 各 todo 提交**只 stage 自己的文件**。
- 干净树基线：`dart analyze lib/` = 0 error/92 warning/635 info；`flutter test test/` = 77 fail **全为环境性 `libsqlite3.so`**（F2 排除清单，此树=prereq commit）；APK `app-release.apk` 148.5MB rc=0（首次 Gradle TLS handshake 瞬时失败，重试成功）。证据：`.omo/evidence/task-1-parity-baseline.txt`。

## Todo 8 — MinePage 作为「设置」tab（2026-10-19）
- `MinePage` 新增公开常量 `static const String tabLabel = '设置'`；AppBar 标题改用它（原 `'我的'`）。**唯一产品改动**——既有入口（工具/性能监控/设置/已安装应用/AI/外观/备份）与 key 全部保留。
- 标签来源：NavigationBar destination 的 label 仍由 `lib/page/home/view.dart`（todo 5 负责，本 todo 禁改）渲染；todo 8 只让页面自身暴露/渲染 设置 标签，供三 tab 外壳引用。
- 新增 `test/page/home/mine_settings_tab_test.dart`（3 断言：常量、AppBar 文案、三入口保留）——MinePage 独立泵起，无需 go_router push。回归套件 `agent_entry_hide_test`（含旧 4-tab `navBarDest('我的')`）/`request_debug_page_test`/`other_pages_border_theme_test`/`backup_module_disable_test` 全绿（28 passed），说明改 AppBar 文案无副作用。
- 证据：`.omo/evidence/task-8-settings-tab.txt`（analyze error-count=0；mine 仅存量 warning/info）。

## Todo 9 — appList/discovery 路由 + barrel 导出（2026-10-19）
- `lib/core/routers.dart`：新增 `AppRoute.appList = "/GStore/appList"`、`AppRoute.discovery = "/GStore/discovery"`（紧跟 `appSnapshotList` 之后，格式与既有常量一致）。
- `lib/core/router/app_router.dart`：在 `appSnapshotList` 路由后新增两条 `GoRoute`，builder 直出 `const ApplistPage()` / `const DiscoveryPage()`（经 `page/page.dart` barrel 解析，未改既有直接 import）。
- `lib/page/page.dart`：追加 `export .../home/tab/applist/view.dart` 与 `.../home/tab/discovery/view.dart`（此两步是 app_router 能解析 `ApplistPage`/`DiscoveryPage` 的前提；先加 GoRoute 会报 "isn't a class"）。
- `agent` 路由保持不变（routers.dart:23 / app_router.dart:161-164）。
- 测试 `test/core/router/parity_routes_test.dart`：仿 `perf_routes_test.dart` 仅在路由配置层断言（不 pump 页面，避免 Riverpod/FFI/插件依赖）；覆盖「经真实 `appRouter` 解析到 builder」「未知路径 → null」「path 无重复注册」。
- 验证：`dart analyze lib/` = 0 error（727 info/warning，均既有）；`flutter test test/core/router/parity_routes_test.dart` = 3 passed。证据 `.omo/evidence/task-9-routes.txt`。
- 注意：`dart analyze lib/` 时 LSP 曾报 `lib/core/rust/generated/*` 错误，为 LSP 守护进程陈旧（analyze CLI 实测 0 error），勿据此改动生成文件。

## Todo 4 — additive three-tab index model (2026-10-19)
- Added `enum HomeTab3 { features(功能,0), home(首页,1), settings(设置,2) }` in `lib/page/home/state.dart` with `tabIndex`/`label`/`static const count=3`/`static fromIndex()`; plus `const homeTab3Order = HomeTab3.values` in `lib/page/home/logic.dart`. **Purely additive: `HomeState`/`jumpToPage`/`sourceIndex` write + 4-tab raw↔display mapping untouched; `view.dart` untouched.**
- Gotcha: Dart forbids a member named `index` on an `Enum`-implementing type → enum field is **`tabIndex`** (renamed after analyzer error `38:13`). `Enum.index` (declaration order) stays separate from the navigation index.
- Tests: new `test/page/home/home_tab3_index_test.dart` (+7); existing `test/agent_entry_hide_test.dart` + `test/navigation_bar_theme_test.dart` GREEN unchanged (4+6+7=17 pass). `dart analyze lib/` = 0 error/92 warning/635 info (= todo-1 baseline). Evidence: `.omo/evidence/task-4-home-state.txt`.
- Concurrency: while working, other workers committed todo 8 (`dc72d87`) and todo 9 (`38444cc`); their files sat staged in the shared index. Committed with a **pathspec** `git commit -- <3 files>` so only my files were included (plain `git commit` would have swept their staged files).
- `.omo/` is gitignored (.gitignore:49); prior parity todos left evidence/notepad untracked → evidence + this note stay local (not force-added), matching project convention.

## Todo 7 — Scene-style DashboardPage (2026-10-19)
- New `lib/page/home/tab/dashboard/view.dart` (`DashboardPage`, `ConsumerStatefulWidget`) + `test/page/home/dashboard_page_test.dart` (5 tests).
- **Data source = existing `perfMonitorProvider`** (`lib/page/perf/logic.dart`) — reuses the perf store; **no new state store**. Base cards (RAM/SWAP, CPU, GPU, per-core, battery, temperature) render from `PerfPageState` and **do not depend on Shizuku**; when the native module is absent they degrade to placeholders ("—"), never crash.
- **Capability gating** mirrors `PerfProfilesPage`'s injectable-loader pattern: `DashboardPage({tunablesLoader, capabilitiesLoader})`; production defaults `PerfModule.instance.tunables` + `PerfCapabilityProbe(shell: PrivilegedShell())`. Probe runs in `initState` via `microtask`, fail-closed to `null`.
- **4 mode buttons are ALWAYS disabled placeholders** (`OutlinedButton.icon(onPressed: null)`, keys `dashboard_mode_{powersave,balance,performance,fast}`); wiring stays todo 29. Reason line key `dashboard_mode_reason`: no writable category → 「无可写控制类别」; probe null/throws → 「未探测」; writable → 「后续版本接入」.
- **Gotcha (grep gate):** the todo acceptance is literally `grep -n "PerfMode"` on the file == 0 — **doc comments count**. Must avoid the literal token even in prose; wrote 「场景模式枚举」 instead.
- **Gotcha (analyzer):** `memory?.usedHuman?.isNotEmpty == true` triggers `invalid_null_aware_operator` warnings (the second `?.` is provably unreachable-null due to short-circuit). Replaced with a `_humanOrDash(String? human, int? kb)` helper.
- Thresholds local const per task-2 §4 (CPU 85/65, RAM 89/80, temp 48/44/41); colors are **theme roles only** (`scheme.error`/`tertiary`/`primary`) — no Scene hex literals (AGENTS.md).
- Verify: `dart analyze lib/` = 0 error, **0 issues in dashboard/view.dart**; `flutter test test/page/home/dashboard_page_test.dart` = 5 passed. Evidence `.omo/evidence/task-7-dashboard.txt` (untracked, per convention).

## Todo 6 — Scene-style FeatureHubPage (2026-10-19)
- New `lib/page/home/tab/feature_hub/view.dart` (`FeatureHubPage`, `ConsumerStatefulWidget` + `AutomaticKeepAliveClientMixin`, `static const tabLabel='功能'`) + `test/page/home/feature_hub_page_test.dart` (5 tests, all green).
- **5 groups exactly per task-2 §2**: 场景模式 / 设备性能 / 充电耗电 / 进阶功能 / 辅助. §2.1 reassignments applied: `battery_stats`(耗电统计)→充电耗电, `perf_profile`(性能配置)→设备性能. Xposed功能 dropped (no equivalent), 交流反馈 kept out of the grid.
- **Every item pushes an existing `AppRoute`** (no new routes): perfProfiles, appList, discovery, perfMonitor, backup, moduleManage, itTools, installedApps, agent, settings, logViewer. test ④ iterates `kHubGroups` and asserts each `entry.route` is registered in the real `appRouter.configuration.routes` → proves no dead link.
- **Gotcha (const):** `AppRoute.*` are mutable `static String` (not `static const`) → the groups list **cannot** be `const`; had to use `final List<HubGroup> kHubGroups = ...` (const-list-with-implicit-const errors at every entry otherwise). `TablerIcons.*` ARE const, keep `const` on Icon widgets.
- **Gotcha (test shadowing):** a local helper named `group(...)` shadows `flutter_test`'s `group()` → "Too many positional arguments". Renamed to `groupFinder`.
- **Layout for testability:** body = `SingleChildScrollView` + `Column` (NOT `ListView`) so all 5 groups mount eagerly and `find.byKey('feature_item_*')` works without scrolling; `ListView` would lazily mount offscreen tiles and break the finders.
- **Module gate mirror of `mine/view.dart`:** `_agentModuleOnline = isModuleEnabled('agent_tools')` + `watchModule('agent_tools')` subscription (cancelled in dispose); AI 助手 item has `requiresAgentModule: true`, filtered out when offline. **Gotcha:** `isModuleEnabled` returns `true` for an *unregistered* module, so the test must register+activate the module before `setModuleEnabled(false)` to observe the hidden state.
- **Tokens only:** all colors/fonts from `Theme.of(context)`; spacing/radius from `AppSpacing`/`AppRadius`; icons verified to exist in `flutter_tabler_icons` 1.43.0. No hardcoded hex/size.
- Verify: `dart analyze lib/` = **0 errors** (727 info/warning, = baseline); `dart analyze <2 new files>` = No issues; `flutter test test/page/home/feature_hub_page_test.dart` = 5 passed. Evidence `.omo/evidence/task-6-feature-hub.txt` (force-added, matching task-9 precedent).
- Concurrency: only new files touched; committed with a pathspec `git commit -- <3 paths>` under `flock` so concurrent workers' staged files are never swept.

## Todo 5 — HomePage Scene-classic 3-tab shell (2026-10-19)
- `lib/page/home/view.dart`: HomePage now renders **3 destinations 功能/首页/设置** → PageView children `FeatureHubPage`(0) / `DashboardPage`(1) / `MinePage`(2). Labels + tabIndex come from the existing `HomeTab3` enum (added `import 'state.dart'`); nav icons `layout_grid(_filled)` / `home(_filled)` / `settings(_filled)`.
- Removed: AI `PageView` child + `AgentPage` import, `view.dart` `sourceIndex` reads, `_displayIndex`/`_rawIndex`, the AI `PopScope` (and the now-constant `isAiTab` slide-out wrapper `AnimatedSlide`/`ExcludeSemantics`/`IgnorePointer`), dead `_agentModuleEnabled`/`_agentSub` + their initState/dispose wiring, and now-unused imports (`applist/view.dart`, `agent/view.dart`, `discovery/view.dart`). `notifier`/`homeState` are still used (controller + index).
- **KEPT (do NOT pre-empt todo 32):** `sourceIndex` FIELD + `setHomeAgentTab` call in `state.dart`/`logic.dart`; `HomeTabVisibility` untouched; `AgentPage` untouched.
- **Cross-fade logic preserved as-is** (`_TabFadeThrough`/`_crossFadeTo`/`_onFadeTick`/`_onIndexChanged`/`_listeningIndex`) — indices are generic, so 4→3 tabs needed no change there. `onDestinationSelected` is now `_crossFadeTo` directly (identity mapping, no raw↔display).
- Tests rewritten in the SAME commit:
  - `test/navigation_bar_theme_test.dart`: geometry test ④ now measures **3** glyphs `[layout_grid_filled, home, settings]` with the equal-split formula `bar.left + bar.width*(2i+1)/6` (was `/8`, 4 glyphs). `[navbar-measure] … delta=0.0` for all 3. Theme-merge test ③ unchanged.
  - `test/agent_entry_hide_test.dart`: dropped the entire invalid 「首页底部 tab」group (4-tab `navBarDest`, display/raw mapping, `sourceIndex` auto-return ⑤); KEPT the still-valid 「我的页 quick action」group (④/④b) testing `MinePage`'s own `_agentModuleOnline` gate. Removed now-unused imports (`home/view.dart`, `home/logic.dart`).
  - NEW `test/page/home/home_tabs_test.dart` (4 tests): 3 destinations + no AI/发现/我的; initial tab 0 → FeatureHubPage; switch 首页→DashboardPage / 设置→MinePage / back→FeatureHubPage with `NavigationBar.selectedIndex` + `homeProvider.index` sync; labels vs `HomeTab3` + page `tabLabel` constants.
- **Highest-risk gotcha (test hermeticity):** the 首页 tab is `DashboardPage`, whose production `_tunablesLoader` calls `PerfModule.instance.tunables()` (the SINGLETON — not routed through a provider override). In a widget test this reaches `ModuleBootstrap`. Fix: `ModuleBootstrap.instance.debugConfigure(ensureOverride: (…)=>throw StateError(…), delayOverride: (…)=>Future.value())` in setUp + `debugReset()` in setUp/tearDown → production path fails FAST with zero-delay backoff (**no FFI / no pending Timer that would fail the widget test**). The page catches it (「控制能力探测失败（fail-closed）… PERF_MODULE_UNINSTALLED」), cards degrade to placeholders, and `pumpAndSettle` succeeds (no infinite AppLoading: availability=absent ⇒ `moduleReady=false` ⇒ `refresh()` early-returns with loading=false).
- Evidence `.omo/evidence/task-5-home-shell.txt`: `dart analyze lib/` = **0 errors** (88 warning / 635 info = baseline; note analyze `exit=2` only reflects info/warning findings — the gate is error-count==0); `grep sourceIndex lib/page/home/view.dart` = 0; `grep _agentModuleEnabled|_agentSub` = 0; `flutter test <3 files>` = **10 passed**.
- LSP daemon again reported stale errors in `lib/core/rust/generated/*` + `core/shell/rust_shizuku_runner.dart`; `dart analyze` CLI shows 0 errors there → ignore (matches todo-9 note).
