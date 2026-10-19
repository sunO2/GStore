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

## Todo 11 — ApplistPage 可 push 化（2026-10-19）
- `lib/page/home/tab/applist/view.dart`：**自带 Scaffold 保持不变**（:69），未新增第二个；AppBar 默认 `automaticallyImplyLeading` → push 时自动出 `BackButton`。`onImportSample`（:329）`homeProvider.notifier).jumpToPage(1)` → `context.push(AppRoute.discovery)`；删除不再使用的 `import page/home/logic.dart`（go_router 已 import 于 :6）。
- `widgets/empty_state_widget.dart`：**新增** `import 'package:go_router/go_router.dart'`（`context.push` 必需——barrel `core.dart` 只 re-export `routers.dart`，**不含** go_router）；删除 `page/home/logic.dart` import；`:59` 浏览发现页 → `context.push(AppRoute.discovery)`；**移除「我的频道」按钮**（原 jumpToPage(2) → 已不存在的 mine tab，有意差异记入 todo 31）；文案 `3种方式`→`2种方式`、`:57`/`:172` 由「切换到标签」改为「进入发现页」。
- `widgets/banner_widget.dart` **未改**：其 `PageController.jumpToPage` 是本地轮播循环，与 homeProvider 无关 → grep 门按计划有意排除。
- 测试 `test/page/home/applist_push_test.dart`（2 widgets）：① push 后 `find.byType(Scaffold)`==1 + `find.byType(BackButton)`==1；② 浏览发现页→discovery→`navigator.pop()` 回列表状态保留。不注册 aggregate 模块即降级空态、无网络（「聚合模块未启用」日志为预期）。
- 验证：`grep -rn "homeProvider.notifier).jumpToPage" lib/page/home/tab/applist/` = 0；`dart analyze lib/` = **0 error**（723 issues 全为存量）；`flutter test test/page/home/` = **26 passed**（含 5 个既有套件，无回归）。证据 `.omo/evidence/task-11-applist.txt`。
- 并发坑（同 todo 4）：完成时其他 worker 正改 `lib/page/home/state.dart`/`logic.dart`（移除 `sourceIndex`，todo 32）与 `discovery/view.dart`（todo 12）→ LSP/analyze 期间会看到这些文件的**瞬时**错误；提交用 `flock` + pathspec 只 stage 本 todo 的 3 个文件，不扫入他人改动。

## Todo 32 — AgentPage route-only + AI-tab 脚手架清除 (2026-10-19)
- `lib/page/agent/view.dart` 变**纯路由页**：删 `isTabEmbedded` 参数/字段、`AutomaticKeepAliveClientMixin`、tab 相关的失焦监听、`_buildBackButton`/`showBack`，以及 `_buildFloatingInputWrapper`/`_inputBarClearance` 里对 `homeProvider` 的读取。`initState`/`dispose` 现在**无条件** `setAgentRoute(true/false)`（保留路由行为）。`import '.../page/home/logic.dart'` 随之删除。
- `lib/page/home/state.dart`：删 `sourceIndex` 字段 + ctor/copyWith 参数。`lib/page/home/logic.dart`：删 build() 与 jumpToPage() 里的 `setHomeAgentTab(...)` 两处调用 + 不再需要的 `core.dart` import；`jumpToPage` 简化为单次 `copyWith(index:)`（两分支本就等价）。
- **保留（勿删）**：`HomeTabVisibility`（class + `setAgentRoute`/`agentActive`）在 `lib/core/navigation/home_tab_visibility.dart` 原样；`setHomeAgentTab` 方法定义保留（虽已无调用方），`agent_service.dart:2376` 的 `HomeTabVisibility.instance.agentActive` 不受影响。
- **Gotcha**：删掉 `AutomaticKeepAliveClientMixin` 后必须同步删 `build()` 里的 `super.build(context)`，否则报 `The method 'build' is always abstract in the supertype.`（混合类版本才有具体实现）。
- 新测 `test/page/agent/agent_route_test.dart`（2）：用 `GoRouter`（`/`→push `/agent`）验证 push→`agentActive==true`、pop→false，并断言三个 sourceIndex 派生的 tooltip（返回首页/发现/我的）均 `findsNothing`；禁模块（`ModuleManager.clear`）下页面「Agent 模块未启用」占位且 `takeException()==null`。
- 验证：三条 grep 门禁全 0（`sourceIndex|isTabEmbedded`、`setHomeAgentTab` in logic.dart、`page/home/logic.dart` import）；`dart analyze lib/` = **0 error**（723 存量 info/warning）；`flutter test`（新测 2 + `agent_module_disable`/`agent_entry_hide`/`home_tabs` 共 11）全绿。证据 `.omo/evidence/task-32-agent-route.txt`（force-add，随项目惯例）。

## Todo 10 — 功能网格入口全量映射（2026-10-19）
- `lib/page/home/tab/feature_hub/view.dart`：`kHubGroups` 由 todo-6 首轮 **14 条**扩为**全量 23 条**（场景模式3 · 设备性能2 · 充电耗电2 · 进阶8 · 辅助8）。新增 9 条（均取自 settings_page.dart / mine/view.dart 的可达功能，route 全部既有，**未改 routers.dart / app_router.dart**）：`app_snapshot`(appSnapshotList)、`fdroid_repo`(fdroidRepo)、`cache_manage`(cacheManage)、`database_manage`(databaseManage)、`theme_settings`(themeSettings)、`proxy`(proxy)、`request_debug`(requestDebug)、`qr_tool`(qrTool)、`licenses`(licenses)。
- **有意不入网格**：Scene Xposed功能（无等价物，整组丢弃）、交流反馈（移「设置」tab）；核心浏览流/参数化路由（home/appDetail/search/categoryPage/webView/auth/downloadCenter/updateCenter）与嵌套配置子页（webdavConfig⊂backup、proxyCapture*⊂proxy、agentSettings/localLlm⊂agent）。仅 `agent` 带 `requiresAgentModule` 门禁。
- 新枚举测试 `test/core/router/feature_hub_entries_test.dart`（仿 `parity_routes_test.dart`：**仅路由配置层、不 pump 页面**，import `appRouter` + `kHubGroups`，`TestWidgetsFlutterBinding.ensureInitialized()`）：① 恰好5组+id/标题；② 每组非空+条目 id 全局唯一；③ **遍历全部条目**断言 route ∈ 真实 `appRouter.configuration.routes`，`checked==entries.length` + `>=14` 防静默跳过/空集合；④ 未知路由 false；⑤ 无 xposed/feedback；⑥ 20 个关键路由全在网格。
- 验证：`dart analyze lib/` = **0 error**（723 issues 全为存量；view.dart 单文件 No issues）；`flutter test test/core/router/ test/page/home/` = **37 passed**（新测试 6 + todo6 widget 5 + 既有全绿，无回归）。证据 `.omo/evidence/task-10-entry-map.txt`。
- 坑：`feature_hub_page_test.dart`（todo 6）的 `buildRouter()` 只为 app_list/discovery/agent/perfProfiles 装了占位路由，新条目**未在 widget 测试里被点按**故无需补；真正的死链门禁是纯路由层测试 ③，别再往 widget 测试塞全量占位。
- 并发：其他 worker 正在改 `discovery/view.dart`(todo 12)/`state.dart`(todo 32) → analyze 期会看到其瞬时错误；提交用 `flock` + pathspec 只 stage 本 todo 的 2 个文件。

## Todo 12 — DiscoveryPage 改为可 push 页面（2026-10-19）
- 路由 `AppRoute.discovery` + GoRoute 由 todo 9 已加；feature_hub 已有 discovery 网格项（可达）。本 todo 是**把页面从「首页 tab 嵌入」语义收尾为「独立路由页」** + 补 widget 测试。
- `lib/page/home/tab/discovery/view.dart` 唯一产品改动：
  - 删除 `AutomaticKeepAliveClientMixin`（`wantKeepAlive=>true` + `super.build`）——该页 provider 是 `autoDispose`，pop 即销毁，作为路由页保活无意义（**注意**：todo 11 的 applist 保留了自己的 mixin；applist provider 语义不同，勿盲目对齐）。
  - 网格底部内边距 `80 + padding.bottom` → `AppSpacing.lg + padding.bottom`：80px 是旧首页 `extendBody`+悬浮导航胶囊的避让遗留，路由页无胶囊。（`home/view.dart:164` 仍是 `extendBody:true` + 悬浮胶囊，但 discovery 不再嵌在其内。）
  - 加类文档说明「自包含可 push 页 / 唯一 Scaffold / AppBar 自动返回」。
- 新增 `test/page/home/discovery/discovery_route_test.dart`（4 用例，全绿）：① 真实 `appRouter` 注册 discovery 且 builder 非空；②③ push 后页面构建（预置应用可见）+ 页面自身**恰好一个 Scaffold** + `BackButton` + 标题「发现」；④ 点 BackButton pop 回上一页；⑤ `router.go(/GStore/__does_not_exist__)` → 自带 `errorBuilder` 兜底，不构建 DiscoveryPage。用 `_SeededDiscoveryNotifier` 覆盖 `discoveryProvider` 避免真实渠道加载。
- **Gotcha（并发编译失败）**：首次跑测试时另一 worker 正在改 `lib/page/settings/settings_page.dart`（`_buildLogDebugSection` 暂缺）→ 整仓编译失败波及我的测试文件。**这是并发瞬态**，等该文件 `dart analyze` 恢复后重跑即过；不要据此改自己的代码。
- **Gotcha（Scaffold 计数）**：`find.byType(Scaffold)` 默认跳过 offstage 的上一路由，故 push 后 `findsOneWidget` 成立（与 applist_push_test 一致）；同时用 `find.descendant(of: DiscoveryPage, matching: Scaffold)` 显式断言「页面自身唯一 Scaffold」更稳。
- 验证：`dart analyze lib/` = **0 error**（723 issues，全 info/warning）；`flutter test test/page/home/discovery/discovery_route_test.dart` = **4 passed**；回归 `other_pages_border_theme_test.dart + parity_routes_test.dart` = **9 passed**。证据 `.omo/evidence/task-12-discovery.txt`（`.omo/` gitignored，未提交，循项目惯例）。

## Todo 13 — 设置 tab 分组对齐 Scene（2026-10-19）
- Scene 设置页 = `ActivityOtherSettings`（`/tmp/vtools/app/src/main/res/layout/activity_other_settings.xml`）：三张卡 → 任务所列五组 = **SELinux**（`settings_disable_selinux`,`strings.xml:71`）/ **主题**（`settings_theme`:73 + 主题色按钮 + `settings_theme_wallpaper`:74）/ **通知**（`settings_black_notification`:84，位于主题卡内）/ **调试**（`settings_debug_layer`:76 / `settings_help_icon`:78 / `settings_auto_exit`:80）/ **日志**（`settings_logcat_title`:82 错误日志）。
- GStore 映射（复用既有条目，零新增功能/键）：主题→「外观」组+MinePage 外观卡；SELinux→「安装与权限」组（Shizuku）；通知→「下载」组（GStore 无独立通知外观设置，取语义最近）；调试/日志→**新增「日志与调试」组**复用既有路由 `logViewer`/`proxy`/`requestDebug`（与 MinePage 工具卡同源）。
- 实现：`settings_page.dart` `_buildSectionHeader(title, {sceneGroup})` 保留原分组名（左侧不动）并在右侧加 `Scene · <组>` 徽标；`mine/view.dart` 外观卡/工具卡加 `_sceneGroupBadge`（`Scene · 主题` / `Scene · 调试 / 日志`）。
- **缺失目标页→禁用行**：`GoRouter.maybeOf(context)?.configuration.findMatch(Uri.parse(route)).matches.isNotEmpty`（go_router 14.8.1：未匹配返回 `_errorRouteMatchList`，其 `matches == const []` → 判 false）。据此 `enabled` / `onTap` 降级，subtitle 显示「功能不可用」。
- 坑：`SettingsPage` 在多数既有测试里用 `MaterialApp(home:)` **无 GoRouter** → `maybeOf` 返回 null → 新行禁用；断言/操作既有行的测试不受影响。
- 坑：`module_manage_page_test` 断言 `find.text('数据与同步')` findsOneWidget 且在 800x1400 视口内构建 —— 故**未改分组顺序/名称**，只加右侧徽标；新增组置于「下载」之后、「关于」之前。
- 坑：`test/page/settings/` 下 pump `MaterialApp.router` 必须包 `ProviderScope`（`settings_page.dart` 用 `Consumer` watch `themeProvider`），否则 `Bad state: No ProviderScope found`。
- 验证：`flutter test`（新增 4 + 7 个回归文件）= 46 passed；`dart analyze lib/` = 0 error。证据 `.omo/evidence/task-13-settings-groups.txt`。

## Todo 18 — BatteryHistoryStore（Scene `battery-history` 等价，2026-10-19）
- 新增 `lib/core/perf/battery_history.dart`（模型+聚合纯函数）+ `battery_history_store.dart`（持久化+查询委托）+ `test/core/perf/battery_history_store_test.dart`（12 用例）。**未碰任何他人文件**；只 stage 本 todo 3 个文件 + 证据。
- **schema 逐字对齐 Scene**：`power8.records(time,session,temperature,status,mode,current,voltage,package,screen_on,capacity)`（task-33）。JSON 键=列名。`voltage` DDL 声明 int 但 Scene 插 `Double`→实际 REAL，故模型用 `double` 存**原始操作数**（不换算）。
- **机制差异（已文档化）**：Scene 用 SQLite（`power8`），GStore 无 SQLite 依赖、全部 perf store 走 `shared_preferences` 单键 JSON → 本 store 沿用 GStore 约定（键 `battery_history_records`），但**字段 schema/聚合公式逐字取 Scene**。机制选择写进库文档注释。
- **聚合逐字取 task-33 SQL**（非猜测）：per-app `where session=? and status in(3,4) and screen_on=1 and package!='' group by package,mode order by current`，`power=avg(current*voltage)`、`avg/min/max(temperature)`、`count(current)`；会话功耗 `avg(current*voltage)`（status in 3/4 & screen_on=1）；样本数 `count(current)`。**功率单位标 unverified**（`power8` 不做 `/1000`，对照 fps_history）。
- **容量裁剪**：Scene `f0.l()` 保留 ≤99 **会话** → `kBatteryHistorySessionCapacity=99`；`normalizeBatteryHistory` 保留最新 99 会话（新旧=会话内 max `time`，回退 session id）及其全部记录。
- **宽容解码**：null/空/非 JSON/非数组→空列表；数组内坏条目跳过；字段缺失→Scene 默认（temperature/status/current=-1，其余 0/''）；绝不抛。
- 验证：`dart analyze <两文件>` = No issues；`dart analyze lib/` = **0 error**（723 存量 info/warning）；`flutter test` 新测 = **12 passed**。证据 `.omo/evidence/task-18-battery-history.txt`。
- **并发坑**：收尾时另两 worker 正在改 `lib/page/home/tab/dashboard/view.dart`（阈值 `_kCpuHigh`/`_kRamHigh` 瞬时 Undefined，因 `lib/core/perf/scene_thresholds.dart` 尚未提交）与 `fps_session.dart` → LSP/analyze 期会看到**瞬时**错误；提交用 `flock` + pathspec 只 stage 本 todo 文件，不扫入他人改动。

## Todo 14 — FpsSession scene-parity fields（2026-10-19）
- `lib/core/perf/fps_session.dart`（本文件序列 14→16→17，本 todo 最先动）：新增 4 字段 + `sessionId` 别名。
  - `avgPower`(double,默认 0)/`viewSize`(String,默认 '')/`mode`(**String 自由串**，默认 '')/`temperatures`(**List<double>，GStore-only 非 Scene 字段**，默认 `const <double>[]`)。
  - `sessionId` 是 **getter 别名** `String get sessionId => id;` —— **不是新字段**；`toJson` 仍只写 `id`（测试断言无 `session_id` 键）；`fromJson` 仅在 `id` 缺失时回退读 `session_id`（`id` 优先）。
  - JSON 键 `avg_power`/`view_size`/`mode`/`temperatures`；新键往返，旧 JSON 缺键 → 安全默认不抛。
  - `fromRecording` 增可选 `avgPower/viewSize/mode/temperatures`（供 todo 15 recorder 注入，本次定好签名避免 todo 15 再改模型）。
  - `==`/`hashCode` 纳入 4 新字段（`temperatures` 按 `.length` 比对，**沿用既有 `samples.length` 风格**，不引入 `listEquals` 依赖）。
- **未动**：`buildFpsSessionCsv`（CSV 字段对齐归 todo 17）、`fps_session_recorder.dart`(15)、`fps_session_store.dart`。**无 `PerfMode` 引用**。
- 新 helper `_finiteValues(Object?)`：过滤 NaN/±Inf，**保留负值**（电池低温）——与 `_doubleList`（额外滤 `<0`）不同，温度用前者。
- 坑：`id` 与 `session_id` 同时存在时 **`id` 优先**（测试初版写反了对 `session_id` 的期望，已改）。
- 验证：`dart analyze <2 文件>` = **No issues found**；`flutter test test/core/perf/fps_session_model_test.dart` = **12 passed**（+4 新）；整 `test/core/perf/` = **532 passed** 无回归。
- 并发瞬态（同 todo 12）：repo 级 `dart analyze lib/` 期间另一 worker 正在改 `lib/page/home/tab/dashboard/view.dart`（todo 23/29 的 `SceneLoadTier`/`_kTemp*`）→ 报 19 个 error **全在该文件**，与 `fps_session.dart` 无关；本 todo 门禁以「改动文件 0 error」为准。证据：`.omo/evidence/task-14-session-model.txt`。

## Todo 23 — Scene 阈值集中化（2026-10-19）
- 新增 `lib/core/perf/scene_thresholds.dart`（**纯 Dart，无 Flutter import**）：adopted 常量 FPS 45 / 高温 46 / CPU 85·65 / RAM 89·80 / temp 48·44·41（出处 task-2 §4）+ 纯档位解析 `SceneLoadTier`/`SceneTempTier` + `sceneCpuLoadTier`/`sceneRamLoadTier`/`sceneTempTier`（边界语义原样保留：CPU/RAM `>`；temp `≥48` / `>44` / `>41`）。
- **`not aligned` = 空**：task-2 §4.4 确认 5 组阈值全部有据可依；process 阈值 task-2 未取证 → 无可采用项，保持原状。
- **要点：计划点名的文件其实没有阈值**。`lib/page/perf/view.dart`、`third_party_section.dart` 只有 `perf_alert_settings` 告警入口（告警语义，非色档）；`lib/compent/*chart*.dart` 只有 `line_chart.dart`（数据无关自绘，颜色由调用方传，无内建阈值）。**真正的使用站点是 todo 7 的 `lib/page/home/tab/dashboard/view.dart`**（原本自带 7 个私有 `_k*` 常量）——本 todo 在该处集中化（删除 7 个本地常量 + 5 个卡片站点改走共享档位解析）。计划 Refs 的这三处是过时/推测，勿据其在空文件里硬塞常量。
- 告警分离（task-2 §4.5）：`perf_alert_settings.dart` **未改未引**；单测显式断言色档值 ≠ 告警默认（CPU 85≠80、temp 48/44/41≠45、FPS 45≠50），防将来误合并。
- **grep 门坑**：dashboard 残留唯一 `80` 是**布局 bottom padding**（`view.dart:184`，避让悬浮导航胶囊），与 RAM 色档阈值 80 无关 → 误报，明确排除；同时把类 doc 里「CPU 85/65…」的字面量改成指向共享文件的引用，避免粗 grep 误伤。
- 验证：`dart analyze lib/` = **0 error**（723 issues 全存量）；`flutter test scene_thresholds_test.dart + dashboard_page_test.dart` = **13 passed**（8 新 + 5 回归）。证据 `.omo/evidence/task-23-thresholds.txt`（`.omo/` gitignored，未提交，循惯例）。
- 并发：开工时其它 worker 正改 `fps_session.dart`(todo 14) / 新增 `battery_history*.dart`(todo 18/21)；反向地，todo 14/18 的 worker 也观察到本 todo 在 `dashboard/view.dart` 的**瞬时** Undefined（`scene_thresholds.dart` 未提交前）——提交用 `flock` + **pathspec 只 stage 本 todo 的 3 个文件**。

## Todo 21 — ChargeHistoryStore + 充电采样（2026-10-19）
- 新增 `lib/core/perf/charge_history.dart`（模型+门控+会话聚合）+ `charge_history_store.dart`（持久化+裁剪）+ `charge_history_recorder.dart`（1s 采样器）+ `test/core/perf/charge_history_store_test.dart`(13) / `charge_history_recorder_test.dart`(8)。**未碰他人文件**（并发中他人正改 `fps_session.dart`/`battery_history*`/阈值）。
- **schema 逐字对齐 Scene**：真实表是 `com.omarea.store.n`（DB `charge8`，`store_n.txt:372`）`records(time,session,current,voltage,capacity,temperature)`，**不是**计划别名 `charge_history2`。JSON 键=列名；`current` int mA，`voltage` double V，`capacity` int %，`temperature` double ℃（单位来自 Scene CSV 表头，task-33）。派生 `power=current*voltage/1000` 标 **unverified**（Scene 自相矛盾：CSV 写 mW 却又 /1000）。
- **机制差异（已文档化）**：Scene 用 SQLite（DB `charge8`），GStore 无 SQLite、perf store 统一走 `shared_preferences` 单键 JSON → 键 `charge_history`，但字段 schema/查询口径逐字取 Scene。`time` Scene 声明 text 主键实际写 long → GStore 用 int ms。
- **门控逐字取 todo 33 的 `ChargeStat.c()`**（`rea_t33_out.txt`）：`status==2`(BATTERY_STATUS_CHARGING) **且** `Math.abs(current)>100` 才 insert；定时器 `a0.e(5000L,1000L)`=**初始 5s + 周期 1s**。落库 `n.a(session,current,voltage,capacity,temperature)`，`time=System.currentTimeMillis()`，**每拍即写无缓冲**。
  - **移植偏差（已文档化）**：GStore 经 `PerfModule.battery()` 拿到的是 sysfs `status` **字符串**（`battery.rs`），Scene 是 `BatteryManager.getIntProperty(BATTERY_STATUS)==2`；`"Charging"` 即 `BATTERY_STATUS_CHARGING` 的 sysfs 拼写 → Dart 侧 `isChargingStatus()` 按键大小写不敏感匹配 `"Charging"`。`perf.battery` 的**控制反转**：recorder 注入 `ChargeSampler`，默认实现调 `PerfModule.instance.battery()`，异常（如 `PerfModuleUnavailableException`）→ 返回 null 跳过本拍。
- **容量裁剪**：Scene `n.l()` 保留 ≤99 **会话** → `kChargeHistoryMaxSessions=99`；`pruneChargeHistory` 超限时丢弃 `|capacityRatio|` 最小者（`capacityRatio=首容量−末容量`，Scene `n.g()`），并列取更旧 session。记录恒按 `time` 升序。
  - **明确不照搬 Scene 裁剪 bug**：Scene `n.l()` 的三档 `capacityRatio<{5,10,20}` 对任何充电会话恒真（充电时首<末⇒ratio 负），且实现里重复删 `h().get(0)`；只采纳可辩护核心（≤99 会话 + 按摆动保留），保确定性。
- **ApiSurface 给 todo 22**：`summarizeChargeSessions()`（三图读侧可直接用）+ `ChargeRecord.power`。
- 验证：`dart analyze lib/` = **0 error**（723 存量 info）；`flutter test` 两新测试 = **21 passed**。证据 `.omo/evidence/task-21-charge-history.txt`（`.omo/` gitignored，不提交）。
- 坑：`fakeAsync` 定时器用例断言 `initialDelay=Duration.zero` 时 `elapse(1s)` → 初始 tick + 1 周期 = **2** 次落库（准确，非 >=1 模糊断言）；`PerfModule` 门面在纯单测里不触发（sampler 全注入）。

## Todo 16 — 分析助手（fpsFluencyRatio / highTempRatio / avgPower，2026-10-19）
- 新增 **`lib/core/perf/fps_analysis.dart`**（纯 Dart，唯一 import = `scene_thresholds.dart`）；**未改 `fps_session.dart`**（有意选新文件：a. 分析逻辑与模型解耦；b. todo 17 拥有 `fps_session.dart`/`buildFpsSessionCsv`，避免冲突）。计划允许二选一。
- 三纯函数：`fpsFluencyRatio(Iterable<double> samples)` = 有限样本中 `>= sceneFluencyFpsThreshold` 占比；`highTempRatio(Iterable<double> temperatures)` = 有限样本中 `>= sceneHighTempCThreshold` 占比；**`avgPower(Iterable<double> voltageV, Iterable<double> currentMa)`** = 逐拍 `V×I/1000` 均值（GStore 等价定义，对齐 todo 14 的 `FpsSession.avgPower` 文档 / task-33）。
- **阈值全走共享常量**，`fps_analysis.dart` 内**无 `45`/`46` 字面量**（grep 门 exit=1）。**重要坑**：`45`/`46` 出现在 **doc 注释散文**里也会被粗 grep 命中——首版文档写了「值 45/46」被命中，已全部改写为引用 `[sceneFluency...]` 常量名；示例里的 `46.0` 也换成 `47.0`。若将来加 grep 门，记得 doc 注释也算。
- **非有限值语义**：`NaN`/`±Inf` **整样本/整配对忽略**，既不计分子也不计分母；空/全无效 → `0`（`isFinite` 断言）。**ratio 分母保留有限负值**（负 fps/负温自然 < 阈值，不入分子）；`avgPower` **保留电流负号**（充/放物理有意义）。与 `FpsStats`（额外滤负 fps）的差异已在 doc 注明。
- `avgPower` 两序列**长度不等取较短者**逐位配对；任一维非有限 → 该对跳过。仅 `1000`/`0` 为数值字面量。
- 验证：`dart analyze lib/` = **0 error**（723 存量 info/warning，= 基线）；`flutter test` 新测 `fps_analysis_test.dart` = **17 passed**，加 fps_session/scene_thresholds 回归共 **37 passed**。证据 `.omo/evidence/task-16-analysis.txt`。
- 并发：**只新增文件**（+ append-only 证据/notepad），提交用 `flock /tmp/opencode/gstore.git.lock` + **pathspec 只 stage 本 todo 文件**，不扫他人 staged 改动。

## Todo 20 — 耗电统计 UI（battery stats page, 2026-10-19）
- 新增 `lib/page/perf/battery_stats_page.dart`（`BatteryStatsPage`，StatefulWidget）+ `test/core/router/battery_stats_route_test.dart`(2) + `test/page/perf/battery_stats_page_test.dart`(4)。路由：`AppRoute.batteryStats="/GStore/batteryStats"`（routers.dart，紧跟 perfProfiles）+ GoRoute（app_router.dart）+ `page/page.dart` export。**未碰他人文件**（并发中他人正改 main.dart(todo19)/fps_session_recorder.dart/logic.dart）。
- **复用 todo-18 store**（构造函数注入 `BatteryHistoryStore?`，生产默认 `SharedPrefsBatteryHistoryStore`；测试注 `InMemoryBatteryHistoryStore` 避 `shared_preferences` 通道）。**无第二 store/引擎**。
- **按应用** = 逐字复用 `aggregateAppPower`（`battery_history.dart`，Scene `power8` SQL 口径）。**按时间** = 页内纯函数 `_summarizeSessions`：时长=`max(time)-min(time)`；温度排除 Scene 默认 -1（`temperature<0`）；**估算 mAh = 对有效功耗样本梯形积分 ∫ current(mA) dt(h)**（派生展示量，非 Scene 表字段；功率单位仍 unverified）。
- 组件：`AppSegmentedButton<_StatsMode>`（按时间/按应用）+ `perfMetric`/`perfSectionHeader`（perf_common）；空状态 `battery_stats_empty` + 刷新动作；清空走 `AppDialogs.showConfirmSheet(isDangerous:true)`；loading `AppLoading`。颜色/字号全走 Theme 令牌。
- **测试坑**：初始 seed 里两个会话电流区间都取 100→200，导致两卡都渲染 `150 mAh`，`find.text('150 mAh')` 命中 2 个 → 把旧会话改成 100→300（200 mAh）使断言唯一。泵帧用循环 `pump(30ms)`（AppLoading 无限动画，勿 pumpAndSettle）。
- 验证：`dart analyze lib/` = **0 error**（724 存量 info/warning；唯一新增式 info 为 app_router.dart:111 既有 prefer_const_constructors）；`flutter test test/core/router/ test/page/perf/` = **97 passed**（含新 6）。证据 `.omo/evidence/task-20-battery-stats.txt`（`.omo/` gitignored，不提交，循惯例）。
- 并发坑（同 todo 4/11/14）：LSP 报 `core/rust/generated/*` + `rust_shizuku_runner.dart` 陈旧 error，且收尾时 `main.dart` 报 `_startBatteryHistoryRecorder` undefined（另一 worker todo 19 进行中）——**均非本 todo**，提交用 `flock` + pathspec 只 stage 本 todo 6 个文件。

## Todo 19 — 电池历史写入器 + 生命周期接线（EXPLICIT manifest 决策，2026-10-19）
- 新增 `lib/core/perf/battery_history_recorder.dart`（`BatteryHistoryRecorder` ChangeNotifier + `BatteryHistorySample` + `batteryStatusFromLabel` + 门控/构造纯函数 + App 级单例 `batteryHistoryRecorder`）；改 `lib/main.dart`（import + `main()` 内 `_startBatteryHistoryRecorder()` 启动，try/catch 静默）；新增 `test/core/perf/battery_history_recorder_test.dart`(16)。
- **门控逐字取自反编译 `com.omarea.data.customer.PowerStat`**（`/tmp/opencode/scene8/rea_t33_out.txt`，注意此前只在 task-33 提了 `f0.k` 插入路径，写入器的**节拍/屏幕/状态**门控要单独反编译 PowerStat 才能拿到）：`e(1000L,3000L)`（初始 1s+周期 3s）；`if (GlobalStatus.p.h()) return;` 即 **status==2(CHARGING)||5(FULL) 不采样**；`zC=this.h.c()` 屏幕亮才起表、熄屏停表；`|current|>10000`（非充电）功率尖峰轮换会话。查询侧仍是 task-33 的 `screen_on=1 and status in (3,4)`。
- **sysfs 字符串→Android 状态码**：`batteryStatusFromLabel`（Charging→2/Discharging→3/Not charging→4/Full→5/其它→1）。`BatteryReport.status` 是 sysfs 字符串（`battery.rs`），故不能直比 int。
- **安全偏差（已入证据）**：GStore 对不完整/非有限数值**跳过该拍**（不落 Scene 的 `-1` 哨兵，避免污染聚合）；`voltage<=0` 丢弃；熄屏改为**跳过**而非停表（screen 事件未接线）；`mode` 默认空串（profile 标签映射属 todo 24/25，不猜）。
- **EXPLICIT manifest 决策 = NO manifest change required（diff 空）**：记录器是进程内 Dart Timer，**不新增 Service** → 无 `foregroundServiceType` / 无 `FOREGROUND_SERVICE*`；电池经既有 Rust `PerfModule`（不需权限，且 `BATTERY_STATS` 是签名权限本就不可申请）；屏幕/前台经既有 **Shizuku** 通道（Shizuku 授权在 App 外部，**零 manifest 权限**）。跨进程后台采样需前台服务 → **明确 out of scope**（残余限制已记）。
- 默认采样器复用 `ForegroundWatcher.parseScreenOn`（`show` 导入，不复制解析逻辑）；屏幕探测 **fail-open**（不确定→视亮屏，同 ForegroundWatcher），Shizuku 不可用→`result.ok==false`→静默降级。
- 会话 id 默认 = 启动墙钟 ms（每次 App 运行唯一；Scene 用 SQLite `f0.l()` 自增），可经构造/`start(session:)` 覆盖；容量裁剪仍归 todo-18 store。
- 验证：`dart analyze lib/` = **0 error**（723 存量 info/warning = 基线）；`flutter test test/core/perf/battery_history_recorder_test.dart` = **16 passed**。证据 `.omo/evidence/task-19-battery-recorder.txt`（`.omo/` gitignored，不提交）。
- 并发：提交用 `flock /tmp/opencode/gstore.git.lock` + pathspec 只 stage `battery_history_recorder.dart`/`main.dart`/测试；**不动 manifest**（决策即不改）。注意并发 worker（todo 20）当时已在改 routers/app_router/page.dart + battery_stats_page，且其 notepad 提到「收尾时 main.dart 报 `_startBatteryHistoryRecorder` undefined」——那正是本 todo 半成品状态，现已定义。
- **⚠️ 并发提交坑（重要，后续 worker 必读）**：`flock` 只串行化「进入锁的 `git add && git commit`」，**不会清空锁外别的 worker 已 pre-staged 的 index 条目**。本次提交用了**裸 `git commit`**（提交整个 index），结果把并发 worker（todo 15）已 staged 的 `fps_session_recorder.dart` / `page/perf/logic.dart` / `test/core/perf/fps_session_recorder_test.dart` 一并卷进本 commit（`git show 3649321` 有 7 files 而非 3）。**正确姿势：提交时用 pathspec 形式 `git commit -- <你的文件>`（只提交指定路径，忽略 index 其余条目），而不是裸 `git commit`**。本次未改写共享历史（3 个 worker 活跃中，rebase/reset 会波及他人），内容已完整提交、树为绿，仅 4 个文件的归属 commit 交错——已在证据中记录。次优可接受：先 `git status --porcelain` 确认无他人残留 staged 再提交。

## Todo 15 — FpsSessionRecorder 采样 temp/power/size/mode（2026-10-19）
- `lib/core/perf/fps_session_recorder.dart`：新增可注入 **环境采样 seam**（帧率 `sampler` 保持不动）：
  - `class FpsEnvironmentSample`（可空字段 temperatureC/voltageV/currentMa/viewSize/mode）+ `typedef FpsEnvironmentSampler`；ctor 增 `environmentSampler`（默认 `null` = 不采样 → 安全默认）。
  - 新 getter `temperatures`/`avgPower`/`viewSize`/`mode`；`stop()` 把四者经 `FpsSession.fromRecording(avgPower/viewSize/mode/temperatures:)` 落盘（todo 14 定好的签名，未改模型）。start/stop/cancel 均重置。**1s 间隔 / 30min 自动停 / 幂等 / 软失败全保留**。
  - **单位（已记录）**：temperatures=**℃**（仅滤非有限，**保留负值**）；avgPower=**W**=`voltage_v×current_ma/1000` 逐拍均值（**仅当电压+电流同时有限**才计该拍，符号保留，无样本 0）；viewSize=**逻辑像素**串 `'1080.0x2340.0'`（取最近非空）；mode=自由字符串（最近非空，缺省空串）。
  - 语义：**每拍独立采环境**（帧率 null/非法仍采）；env sampler 抛异常 → 跳过该拍环境不中断；返回 null/含 NaN/Inf → 跳过相应项。**无 `PerfMode` 引用**。
- `lib/page/perf/logic.dart`：`fpsSessionRecorderProvider` 注入 `environmentSampler` —— `perfModuleProvider.battery()`（present 时取 temperatureC/voltageV/currentMa，失败软降级）、温度 null 时回退 `thermal().maxTempC`；`viewSize` 经新私有 `_logicalViewSize()`；`mode: ''`。新增 `import 'package:flutter/widgets.dart' show WidgetsBinding;`。
  - **viewSize 取法（计划要求「记录选择」）**：录制器纯 Dart 读不到 `MediaQuery` → 接线层用 `WidgetsBinding.instance.platformDispatcher.views.first` 的 `physicalSize / devicePixelRatio`（= 逻辑像素，`MediaQuery.size` 的规范构成）；无视图/非法值 → null → 降级空串，绝不抛。
  - **mode 取法**：GStore 尚无「当前生效 profile 标签」运行时（每应用 profile 由前台驱动、4 档运行时在 todo 24/29）→ 缺失即空串；seam 收自由串，todo 29 可零改 recorder 接入。
- 测试 `test/core/perf/fps_session_recorder_test.dart`：**+4**（共 11 passed）——① 记录温度序列/avgPower 均值/viewSize/mode 并落盘；② 跳过 NaN/Inf/空串、保留负温度、仅电压+电流同时有限才计功率；③ env 抛异常跳过且帧率无效时仍采环境；④ 未注入 env sampler → 默认值。
- 验证：`dart analyze lib/` = **0 error**（724 存量 warning/info，+1 系并发他人改动）；两改动文件单文件分析 **No issues**；recorder 测试 **11 passed**；回归 `perf_fps_session_test` + `fps_session_model_test` = **14 passed**。证据 `.omo/evidence/task-15-recorder.txt`（.omo/evidence 被 .gitignore 忽略，未提交；learnings.md 已跟踪，随本 todo 提交）。
- 并发：仅动本 todo 的 3 个文件；提交用 `flock` + **pathspec**（`git add -- <3 files>` + `git commit -- <files>`）避免扫入他人 staged（`lib/main.dart`/`battery_history_recorder*` 等）。LSP 仍报 `lib/core/rust/generated/*` 陈旧错误 → CLI `dart analyze` = 0 error，忽略。
- **并发事故（重要）**：本 todo 首次 `git add -- <4 files>` 因 learnings.md 位于被忽略的 `.omo/` 而**非零退出**，导致 `&& git commit` 未执行，但 3 个代码/测试文件**已被 stage**。修复期间另一 worker（battery-history recorder）用共享索引提交 `3649321`，把我的 `fps_session_recorder.dart`(+143)/`logic.dart`(+70)/`fps_session_recorder_test.dart`(+176) **一并扫入其提交**。随后我用 `git add -f learnings.md` + pathspec commit 生成 `3140853`（仅含 learnings.md）。**代码变更已在 HEAD 树中且测试全绿**；无法改历史（并发 + 禁 amend/force）。教训：被忽略路径混入 `git add` 会让整条命令失败却部分生效——`git add` 应**排除 `.omo/`（或对已在索引的 `.omo` 文件单独 `-f`）**，且 stage→commit 必须在**同一次 flock 内一次成功**。

## Todo 22 — 充电曲线 UI（charge curve page）（2026-10-19）
- 新页 `lib/page/perf/charge_curve_page.dart`（**复用 todo-21 `ChargeHistoryStore`，无第二 store**）：三张图横轴均为**容量 (%)**（Scene `select capacity,<metric>,time order by time`），纵轴 = 电流(mA) / 温度(℃) / 功率(`current*voltage/1000`，单位 `unverified`)。plan 文字第三图记「时间-容量」，按 todo-33 的第三序列（`capacity+power+time`）实现为**功率-容量**（时间用于排序），已在证据中说明对应关系。
- 纯函数 `chargeCurveSeries(records, session:)` = 按会话过滤 + 按容量升序（同容量按时间）→ 三图样本序；会话分组复用 `summarizeChargeSessions`。
- 图表复用 `lib/compent/line_chart.dart` 的 `LineChart`（零第三方依赖）；颜色走 `colorScheme`（current→primary、temperature→tertiary、power→secondary）；loading `AppLoading`；空态仍渲染**三张空图表**。路由/桶照 todo-20 模式：`AppRoute.chargeCurve` + `GoRoute` + `page.dart` export。
- **受控 Dropdown 坑**：`DropdownButtonFormField` 的 `initialValue` 只在首帧生效，`setState` 切换会话**不会**刷新显示 → 本页改用受控 `DropdownButton`（`value:` 随 state）包在 `InputDecorator` 里，切换后容量范围正确更新。后续做「选会话/选项切换」的页面注意同一坑（battery_stats 的 byApp 下拉同理，只是其测试未覆盖切换）。
- 验证：`dart analyze lib/` = **0 error**（723 存量 = 基线，未新增）；新测试 **6 passed**；回归 `flutter test test/core/router/` = **15 passed**。证据 `.omo/evidence/task-22-charge-curve.txt`（`.omo/evidence` 被忽略，未提交）。
- 并发：与 todo 17（FPS reports UI）并行；只动 `charge_curve_page.dart` + routers/app_router/page.dart + 2 测试；提交用 `flock` + **pathspec** `git commit -- <files>`（含 `git add -f` 处理被忽略的 `.omo` 证据路径）。

## Todo 17 — FPS 会话 UI 显示 Scene-parity 指标 + CSV 对齐（2026-10-19）
- `lib/page/perf/reports_page.dart`：`_sessionTile` 副标题追加 2 行（`流畅度 p% · 高温占比 p% · 功耗 x.xx W` + `模式 … · 视图 …`，非空才显示；maxLines 2→3）；新增 `onTap` → `_showSessionDetail`（`AppSheet.showCustom`+`AppSheetScaffold`+`perfKv`：模式/视图尺寸/平均功耗/流畅度/高温占比 + 既有统计）。
  - 比率**复用 todo-16 纯函数** `fpsFluencyRatio`/`highTempRatio`（不内联重算）；新增文件级 `_sceneRatioPercent(ratio,{hasSamples})`（无样本 → `—`，有样本 → `67%`）与 `_scenePowerText`（`x.xx W`）。颜色/字号走 Theme、间距圆角走 AppSpacing/AppRadius 令牌。
- `lib/core/perf/fps_session.dart`（`buildFpsSessionCsv`，**本 todo 拥有该文件**）：+ `import fps_analysis.dart`；旧 meta 列**原样保留**，仅追加 `mode`/`view_size`/`avg_power`/`fluency_ratio`/`high_temp_ratio`（后两者经 helper 计算，空会话 → `0.0`）。空会话仍产出有效 `key,value` + `index,fps` 表头。
- 测试：`test/core/perf/fps_session_model_test.dart` **+2**（14 passed，共）；`test/page/perf/perf_fps_session_test.dart` **+2**（共 4，18 passed）。
  - 坑：详情弹层里断言用**精确 `find.text('均衡')`/`find.text('1.25 W')`/`find.text('67%')`**，而列表里这些值是**长串**（`find.textContaining`）→ 精确/包含两套 finder 不会互相误命中（列表 `'模式 均衡 · 视图 …'` 不会被 `find.text('均衡')` 命中）。列表指标断言用 `textContaining('流畅度 67%')` 等。
- 验证：4 改动文件 `dart analyze` = **No issues found!**；`dart analyze lib/` = **0 error**（723 存量 = 基线）；两目标测试 **18 passed**；回归 `flutter test test/core/perf/` = **600 passed**。证据 `.omo/evidence/task-17-fps-ui.txt`（`.omo/` gitignored，未提交）。
 - 并发：与 todo 22（charge curve + routers）并行；只动本 todo 4 文件 + learnings；提交用 `flock /tmp/opencode/gstore.git.lock` + **pathspec `git commit -- <files>`**（learnings.md 为已跟踪文件，普通 `git add` 即可，无 `-f`）。LSP 报 `core/rust/generated/*` + `rust_shizuku_runner.dart` **陈旧**错误（bridge 生成物），CLI `dart analyze lib/` = 0 error，忽略。

## Todo 30 — Root 可选能力门（root detection + root-only gate）（2026-10-19）
- 新 `lib/core/perf/root_status.dart`：`RootStatus{rooted,reachable,uid,detail}`（`display` 显式「Root 可用（可选）」/「Root 不可用（Shizuku 为主）」）；`RootOnlyCapability.miuiThermalDirectWrite`；`RootDetector`（**可注入 CommandRunner**，默认 `rustShizukuRunner`，经 `PrivilegedShell`）；`RootCapabilityGate`（纯门：`shizukuPrimaryAvailable` **恒真**，`isAvailable(id)` 仅 root 时真，未知 id fail-closed）；`rootDetectorProvider`/`rootStatusProvider`。
  - **FAIL-CLOSED**：仅 `su -c 'id -u'` 哨兵 `ok=1` 且首行 uid==0 才判 root；超时/无输出/未执行/失败/uid≠0 → `rooted:false`。**不**因「`su` 文件存在」就假定可用。探测命令体常量 `kRootProbeBody = "su -c 'id -u'"`（`buildCommand` 会安全转义内嵌单引号）。
- `lib/core/perf/miui_thermal.dart`：新增 **root-only** 动作 `directWriteAsRoot(backup,{confirmed})` —— 先门 Root（无 → `root_required` 且**零 cp 命令**），再走共享 `_restoreVia(asRoot:true)` 经 `su -c 'cp -f …'`；门禁顺序=确认→备份归属→白名单→存在→cp→回读。`restore()` 重构为 `_restoreVia(asRoot:false)`（**默认 Shizuku 逐字不变**）。新增 `MiuiThermalAction{backup,restore,directWriteAsRoot}` + `MiuiThermalActionCapability{id,label,rootOnly,available,reason}` + `actionCapabilities()`（备份/恢复恒 available & label 含「Shizuku」；直写 root-only，无 Root 时 available=false + reason，label「温控直写（需 Root）」）。ctor 增可选 `rootDetector`（默认**共享注入 runner**，使已有测试注入假 runner 时 root 探测也走该假 runner → 无 Root，零影响）。
- 测试 `test/core/perf/root_status_test.dart` **12 passed**：探测器 5（uid0 / uid2000 / err / null不可达 / 缓存+refresh）+ 纯门 2 + 服务门禁 5（无 Root 条目 disabled+reason；无 Root 直写 root_required 零 cp；有 Root 直写经 su 成功+回读；有 Root 缺确认 confirm_required；默认 restore 不经 su）。回归 `miui_thermal_test.dart` **15 passed**（共 27 passed）。
- 验证：`dart analyze lib/` = **0 error**（723 存量 = 基线，未新增）；两改动文件单文件分析 **No issues found!**。证据 `.omo/evidence/task-30-root-gate.txt`（`.omo/evidence` gitignored，未提交）。
- **注意（scope）**：MUST NOT 触碰 pages/routers → 本 todo **未接线 UI**（`hardware_page.dart` 的 `MiuiThermalCard` 未动）；门禁以 `actionCapabilities()` 暴露，UI 消费留待后续 todo。并发：与 todo 24（perf_profile）并行，仅动 3 新/改文件 + 测试 + learnings；提交用 `flock` + **pathspec**（`git commit -- <files>`，含 `git add -f` 处理被忽略的 `.omo` learnings）。



## Todo 24 — PerfMode 枚举 + PerfModePreset + PerfProfile.mode（2026-10-19）
- `lib/core/perf/perf_profile.dart`（**本 todo 拥有该文件**）：新增 `enum PerfMode{powersave,balance,performance,fast}`（`wireName` 稳定小写 / `label` 省电/均衡/性能/极速 / `defaultMode=balance` / 宽容 `fromWire(Object?)`：wireName 大小写不敏感 + 中文标签 + 枚举序号；未知/缺失/越界 → balance，**绝不抛**）。
- 新增 `class PerfModePreset` **只**映射到既有旋钮形状（`cpuClusters`/`gpuLevel`/`cpuset`/`thermalEnabled`，**零新增旋钮**）：`isEmpty`/`empty`/`toJson`/`fromJson`(宽容)/`==`/`hashCode`/`toString` + `forMode(mode)` **设备无关安全回退**（省电→cpuset background+thermalEnabled true；均衡→空；性能→foreground；极速→top-app）。**按 SoC 细化的目标值表归 todo 27**（`perf_mode_profiles.dart`）。
- `PerfProfile`：新增 `mode`（默认 balance，**非 null**，无法区分「未设」与 balance → 默认即 balance 语义）；`isEmpty` 增 `mode==balance`（唯一 mode 项 → 非空）；`copyWith` 加 `mode`；`toJson` **始终**写 `'mode': wireName`；`fromJson` 经 `fromWire`（旧档案缺 mode → balance，**向后兼容**）；`==`/`hashCode` 含 mode → **仅 mode 变化即被引擎 `current==target`（:472）识别为 changed**。
- 测试：`perf_profile_test.dart` 新增 PerfMode 3 + PerfModePreset 5 + PerfProfile.mode 7 组；`perf_profile_auto_engine_test.dart` +1（仅 mode 变化 → refresh 返回 `applied` 而非 `unchanged`）。验证：`dart analyze lib/` = **0 error**（728 存量 = 基线）；`flutter test` 目标 4 文件 **68 passed** + 页面回归 **17 passed**。
- 坑：LSP 报 `core/rust/generated/*` 与 `rust_shizuku_runner.dart` 陈旧错误（bridge 生成物），CLI `dart analyze lib/` = 0 error，忽略即可。并发：与 todo 30（miui_thermal/root_status）并行且**文件不相交**；提交用 `flock /tmp/opencode/gstore.git.lock` + **显式 pathspec**（只提交 perf_profile.dart + 2 测试，**不**动 todo 30 的改动）。证据 `.omo/evidence/task-24-perf-mode-model.txt`（`.omo/` gitignored）。

## Todo 17 follow-up — `mode` CSV 列核验（2026-10-19）
- 复核「`buildFpsSessionCsv` 缺 `mode` 列」的报障：**不成立**。`meta('mode', session.mode)` 已在 `lib/core/perf/fps_session.dart:321`（`view_size`/`avg_power`/`fluency_ratio`/`high_temp_ratio` 之前），且测试 `fps_session_model_test.dart:221` 已断言 `contains('mode,均衡')`。两者均随 **`022c728`** 入库（`git show HEAD:lib/core/perf/fps_session.dart` 已确认含该列）。
- 验证：`flutter test test/core/perf/fps_session_model_test.dart` = **14 passed**；`dart analyze lib/` = **0 error**。**无代码改动 → 无新提交**（空提交会被 git 拒绝；不得伪造）。教训：下手前先 `grep`/`git show HEAD:<file>` 核对现状，避免重复改动。

## Todo 27 — per-SoC 模式常量表 `perf_mode_profiles.dart`（2026-10-19）
- 新 `lib/core/perf/perf_mode_profiles.dart`（**仅常量，无状态/无 IO**）：`enum PerfVariant{active,conservative}`（`defaultVariant=conservative`、宽容 `fromWire`）+ 4 张 `const` 参考表（`k{Lahaina,Kona}{Conservative,Active}ModeProfiles`）+ `kFallbackModeProfiles`（设备无关安全回退，逐值 == todo 24 的 `PerfModePreset.forMode`，测试守护防漂移）+ `kSocModeProfiles`（platform→variant→mode 索引）+ 纯查表 `modeProfilesForPlatform` / `modePresetForPlatform`（未知/空/null platform 或未知 variant **绝不抛** → 回退）。
- 编码值**逐字**取自 Scene `powercfg/{lahaina,kona}/{active,conservative}.sh`：CPU `set_cpu_freq A B C D E F`（policy0/4/7 的 min/max，Hz→MHz）+ `reset_basic_governor` 的 `schedutil`；GPU 存 `gpu_pl_up N` 偏移（0/1/2）；cpuset 存归属组；thermal 恒 `true`（安全方向）。文件头/行内附源注释。
- **显式偏差（治理）**：① Scene `gpu_pl_up` 写 kgsl `min_pwrlevel`（运行时基值），既有应用器把 `gpuLevel` 映射到 `max_pwrlevel` → 本表只存**参考偏移**，方向对齐归 todo 26，**不声称等价**。② Scene `fast` 的 `thermal_disguise 1`（root-only，`board_sensor_temp` 不在白名单）**不编码**；常量表绝不编码关温控。③ Scene 写 4 组 cpuset **掩码**（`*/cpus`），GStore 应用器写**成员表**（`*/tasks`）→ 本表按模式存归属组（powersave→background / performance→foreground / fast→top-app / balance→null）。root-only/unsupported（sched_*/stune/cpuctl/core_ctl/msm_performance/cpu_boost/devfreq-BW/cpu_online/cgroup.procs/taskset/pm/renice/miuibooster）**均未编码**。
- 验证：`dart analyze lib/` = **0 error**（723 存量 = 基线）；单文件 + 测试 `dart analyze` = **No issues found!**；`flutter test test/core/perf/perf_mode_profiles_test.dart` = **15 passed**。证据 `.omo/evidence/task-27-mode-profiles.txt`（`.omo/` gitignored，未提交）。
- 并发：与 todo 25（store/page 每应用 mode）并行且**文件不相交**；只动 2 新文件 + learnings；提交用 `flock /tmp/opencode/gstore.git.lock` + **显式 pathspec**。坑：`git commit -- <新文件>` **不会**提交未跟踪文件 → 先 `git add` 再 pathspec 提交；`dist/` 与并发改动的 `perf_profile_store.dart`/`perf_profiles_page.dart` 保持不动。



## Todo 25 — 每应用 mode 经既有 PerfProfileStore/perf_profiles_page（2026-10-19）
- `lib/core/perf/perf_profile_store.dart`（**本 todo 拥有该文件**）：模式持久化**已由 todo 24 的模型自动覆盖**（`PerfProfile.toJson` 恒写 `mode`、`fromJson` 宽容 → 缺失 balance），故只需**显式化契约 + 便利读写**：`PerfProfileStore` 新增 abstract `modeFor(pkg)`（无档案/缺失 → `PerfMode.defaultMode`）与 `saveMode(pkg, mode)`（**仅改 mode**、保留其它字段；无档案 → 新建 `enabled=false` 的最小档案；空包名 → false）；`ConfigPerfProfileStore` 经 load/save 委托、`InMemoryPerfProfileStore` 直取 map；**CRUD 签名未动**。
  - 坑（Dart）：abstract 类里给方法**写具体实现体**对 `implements X` 的实现类**不生效**（仍报 Missing concrete implementations）；`mixin M on Interface` 也**无法**混入只 `implements Interface` 的类（报 "can't be mixed onto Object because Object doesn't implement ..."）。正解：接口声明为 abstract，两个实现类各自实现（本 todo 就 2 个实现，grep 确认）。
  - page 侧：编辑弹层加 `_mode`（自 `initial.mode`，缺失即 balance）+ `DropdownButtonFormField<PerfMode>`（key `perf_profile_editor_mode`，恒可编辑——mode 是纯本地存储意图，应用由引擎在能力门内做，todos 26/28）；`_submit` 带 `mode`；列表 tile 摘要首位加 `模式 <label>`（原「未配置覆盖项」分支随 mode 恒在而消失，测试无依赖，安全）。
- 测试：store +9（decode 缺失/非法→balance、encode 恒写 mode、Config 往返、旧档案→balance、modeFor 回退、saveMode 保字段/新建/空包名）；page +4（tile 显示、新增默认均衡→选性能保存、既有 fast 预选极速、改省电）。下拉选择写法：`tap(dropdown key)` → `_pump` → `tap(find.text('性能').last)`（关闭态只显示当前项，菜单项唯一，`.last` 稳妥）。
- 验证：`dart analyze lib/` = **0 error**（723 存量 info/warning ≤ todo 24 基线 728）；4 改动文件单文件分析 No issues；目标 **36 passed**；回归 6 文件 **68 passed**。证据 `.omo/evidence/task-25-per-app-mode.txt`（`.omo/evidence` gitignored，未提交）。
- 并发：与 todo 27（`perf_mode_profiles.dart` 常量表）并行且不相交；提交用 `flock /tmp/opencode/gstore.git.lock` + **显式 pathspec**（`git commit -- <files>`，只提交 2 源码 + 2 测试 + learnings.md）。LSP 报 `core/rust/generated/*` + `rust_shizuku_runner.dart` 陈旧错误（bridge 生成物），CLI `dart analyze lib/` = 0 error，忽略。

## Todo 26 — 既有应用器执行 mode preset + 逐字段优先级 (2026-10-19)
- **不新建 applier**：只在 `lib/core/perf/perf_profile_auto_engine.dart` 扩展。新增 import `perf_mode_profiles.dart`；`_applyProfile` 前先 `_modePresetFor(mode)` → `mergePerfModePreset(profile, preset)` 得 `effective`，再逐类应用；`_appliedProfile` 仍存**原始档案**（含 mode）→ `current == target` 幂等/变更检测语义不变（:472）。revert/部分失败回滚路径零改动。
- **逐字段合并（锁定语义）** `mergePerfModePreset`：CPU **每簇+每字段** `explicit?.field ?? preset?.field`（档案未提及的簇整簇取预设）；GPU/cpuset/thermal 各自 `profile.x ?? preset.x`；`package/enabled/mode` 原样保留；空预设原样返回（`identical` 测试）。
- **可注入 seam**：ctor 新增 `String? socPlatform`、`PerfVariant variant=conservative`、`PerfModePresetResolver? modePresetResolver`；默认解析器 = `(mode) => modePresetForPlatform(socPlatform, mode, variant: variant)`。解析**绝不抛**（异常→空预设）。测试 harness 透传 `presetResolver`/`socPlatform`。
- **shizuku-writable 治理**：`PerfModeAction{cpu,gpu,cpuset,thermal}` + `kShizukuWritableModeActions`（= 可达集既有旋钮子集）+ `kSkippedRootOnlyModeActions`（task-3 §3 的 root-only/unsupported 全清单）+ `modeActionsFor`/`planPerfModeActions`。`_applyProfile` 每次 `debugPrint` 应用/跳过集；引擎**绝不**写 `/proc`、`/sys/module`、`/dev/stune`、`core_ctl`（测试断言）。
- **必须改的既有测试**：`仅 mode 变化` 用了 mode=fast；默认（无注入）解析器 = `perf_mode_profiles` 回退表 → fast 会补 cpuset `top-app` 从而改变覆盖项。故该用例显式注入 `(_) => PerfModePreset.empty` 隔离「mode 相等性」语义；预设行为由新组单独守护。**其余既有用例 mode=balance（回退表 = empty）零影响**。
- harness 需给 cpusetNames 补 `foreground`，并 seed `/dev/cpuset/foreground/{tasks,cpus}` 节点（否则预设 foreground 会失败）。
- 新测 +9：纯合并（显式胜/预设补空/空预设零拷贝）、动作集/跳过集断言、fake-shell 逐字段覆盖（9 覆盖项，显式 gpu/cpuset/thermal 全胜、foreground 未写）、回退表填充（未知 socPlatform）、不写 root-only 节点、解析抛异常降级、**capabilities=null（Shizuku 不可用）→ 模式预设也零写入无崩溃**。
- 验证：`dart analyze lib/` = **0 error**（723 存量 = 基线）；2 改动文件单文件分析 No issues；目标测试 **29 passed**；回归 5 文件 **78 passed**。证据 `.omo/evidence/task-26-mode-applier.txt`（`.omo/` gitignored，未提交）。
- 并发/坑（同既往）：LSP daemon 报 `core/rust/generated/*` + `rust_shizuku_runner.dart` 陈旧 error，CLI analyze = 0 error，忽略。提交用 `flock` + **显式 pathspec**（只 2 文件）。

## Todo 28 — 前台/屏幕事件自动模式切换（复用引擎）（2026-10-19）
- **不新建引擎/存储/页面**：只扩展 `lib/core/perf/perf_profile_auto_engine.dart`。新增屏幕维度 + Scene strict/delay，复用 todo 25 `modeFor`/todo 26 `mergePerfModePreset`（mode 经预设逐字段合并后应用）。
- **屏幕维度**：新入口 `onScreenState(bool)` + getter `isScreenOn`。熄屏 → **sleep**：取消待处理去抖（被取代事件报 superseded）+ **立即** reconcile；`_reconcileOnce` 中 `_screenOn == false` 使 target 恒 null → 经会话 `revertAll` 还原（reason `screen_off`；revert reason 新增 `profile_sleep`）。亮屏 → **resume**：经 `debounce+delay` 窗口按最新 `_desiredPackage` 重新收敛。熄屏期间 `onForegroundPackage` 只记录期望、返回 `noop`/`screen_off`、**零写入**；resume 统一收敛。同态重复 → `noop`（零写入）。
- **strict**（ctor `bool strict=false`）：目标 == 当前已应用档案时**跳过** unchanged 短路，强制重应用（Scene `strictMode`）；实现为「先 revert 当前再 apply」（末态正确，代价是重复写；默认路径零影响）。**delay**（ctor `Duration delay=Duration.zero`）：收敛窗口 = `debounce + delay`（Scene `delayToggleConfig`），窗口内新事件取消本次。两者默认值使既有行为**逐字节不变**。
- 抽取共享 `_scheduleReconcile()`（去抖+延迟），`onForegroundPackage` / `onScreenState(true)` 复用；`_tail` 串行 + single-flight 保持；`dispose()` 仍取消定时器 + 完成挂起。**todo 26 前置/precedence/回滚/fail-closed/root-only 跳过全部保留**（`_appliedProfile` 仍存原始档案）。
- 测试：harness 加 `strict`/`delay` 透传；新 9 例（mode apply 且 == `store.modeFor`（仅 mode 档案 → fast 预设 cpuset top-app）；sleep 还原/resume 重应用；熄屏零写入；屏幕幂等；strict 强制重应用；delay 用 `fake_async` 验证窗口内未写+取代；全局关闭零写；未映射 reverted / null noop；dispose superseded）。fake runner/session/controller，零真机/Shizuku。
- 验证：`dart analyze lib/` = **0 error**（723 存量 = 基线；单文件 No issues found!）；`flutter test test/core/perf/perf_profile_auto_engine_test.dart` = **38 passed**（29 既有 + 9 新）；回归 coordinator/profile/mode_profiles/store = **73 passed**。证据 `.omo/evidence/task-28-auto-mode.txt`（`.omo/` gitignored，未提交）。
- **范围边界**：本 todo 只扩展**引擎入口**；屏幕开关事件源接到 `PerfProfilesCoordinator`/生命周期属组装层，未在本 todo（未改 coordinator/page）。设备未验证。
- 坑（同既往）：LSP daemon 报 `core/rust/generated/*` + `rust_shizuku_runner.dart` 陈旧 error（bridge 生成物），CLI `dart analyze lib/` = 0 error，忽略。提交用 `flock` + **显式 pathspec**（只 2 文件 + learnings.md）；`git add` 新文件后才能 pathspec 提交。

## Todo 29 — 能力感知模式 UI（仪表盘四按钮接线 + 页面快捷模式选择器）(2026-10-19)
- **不新建 store/engine/page**：只扩展既有 `perf_profile*`。核心语义决策：GStore 的模式是**每应用**的，仪表盘是「全局快捷」→ 4 档按钮把所选 `PerfMode` 经**既有 `PerfProfileStore`**（`loadAll`/`saveAll`）应用到**全部按应用档案**，写入后由既有 `PerfProfileAutoEngine`（todos 26/28）在下次前台/刷新收敛。**未**新增全局 config 键、**未**新建第二套存储。
- 新共享纯函数放 `lib/page/perf/perf_profiles_tile.dart`（该文件是 todo 29 点名可改的 perf 支撑文件；不放进被禁的 `perf_profile*.dart`/`perf_mode_profiles.dart`）：`applyPerfModeToAllProfiles(store, mode) -> Future<int?>`（`0`=无档案、`null`=失败、绝不抛）与 `commonPerfModeOf(map) -> PerfMode?`。dashboard 与 page 都 import 它复用（避免逻辑重复）。
- `dashboard/view.dart`：`_ModeButtonSpec.id/label`（字符串常量）→ `mode: PerfMode` + 用 `mode.wireName` 做 key（`dashboard_mode_{powersave,balance,performance,fast}` **逐字不变**，测试无碍）+ `mode.label`。新注入 seam：`store`/`modeApplier`(`Future<bool> Function(PerfMode)`)/`modeReader`(`Future<PerfMode?> Function()`)，生产默认走 `ConfigPerfProfileStore`。能力门=`_probed && caps!=null && PerfControlCategory.values.any(isCategoryAvailable)`；不满足→4 按钮 `onPressed:null` + `dashboard_mode_reason` 可见原因（保留原有「无可写控制类别」/「未探测」子串，旧测试断言不破）。生效模式高亮（`TablerIcons.check` + `secondaryContainer`）。
- **关键坑（测试宿主平台通道）**：dashboard 测试原来不注入 store → 默认 `ConfigPerfProfileStore` 会触达 `shared_preferences`；现 harness 默认注入 `InMemoryPerfProfileStore()`。`_readCommonMode`/`applyPerfModeToAllProfiles` 全程 try/catch，缺失通道下返回 null/{}/false，绝不崩。
- `perf_profiles_page.dart`：新增**页面级**「快捷模式」卡片（`perf_profiles_mode_card`；受控 `InputDecorator`+`DropdownButton<PerfMode>`，key `perf_profiles_mode_selector`，reason key `perf_profiles_mode_reason`）。**受控**（`value:` 随 state）而非 `DropdownButtonFormField`——遵循 todo-22 记录的 `initialValue` 只在首帧生效坑。页面级能力探测在 `initState` 后 `Future.microtask`（注入加载器；生产 best-effort，绝不阻塞首帧；catch→null→禁用）。**编辑弹层**的 `perf_profile_editor_mode` 也改为能力感知（无 writable/未探测→`onChanged:null`+helper 原因），覆盖 todo-25 的「恒可编辑」。
- 测试：dashboard **+1**（点击 fast→store 两档案 mode 均更新 + 「已应用「极速」」可见；原「恒禁用占位」测试改为「已接线可用」）；page **+5**（页面级选择器可用应用到全部 / 无 writable 禁用+原因 / null 未探测禁用 / 编辑弹层无 writable 禁用 / 编辑弹层可用）。断言用 `tester.widget<DropdownButton<PerfMode>>(...).onChanged`；页面 tile 摘要含「模式 均衡」等长串，弹层内选值仍用 `find.text('性能').last`。
- 验证：`dart analyze lib/` = **0 error**（723 存量 info/warning = 基线，`grep -cE '^\s+error -'`=0）；3 改动含 2 测试文件单文件分析 No issues；目标两套 **22 passed**；回归 `test/page/perf/ test/page/home/ test/page/settings/perf_profiles_settings_test.dart test/core/perf/` = **806 passed**。硬编码颜色/`log(` grep 门 = none。证据 `.omo/evidence/task-29-mode-ui.txt`（`.omo/` gitignored）。
- **范围/偏差**：生产 `PerfProfileAutoEngine` 私有于 `PerfMonitorModule`（无 provider），dashboard 不可直达 → 走 store 写入（引擎的输入路径）；未改 module/router/coordinator。设备未验证（Shizuku/root）。todo 7 的「不 import PerfMode」验收被 todo 29 **有意取代**。

## Todo 28 follow-up — 生产屏幕事件接线（gap fix）（2026-10-19）
- **Gap**：上一提交只加了引擎入口 `onScreenState`，`lib/` 无生产调用点（`grep -rn onScreenState lib/` 仅定义）。
- **Fix（复用既有屏幕探测、零 manifest 变更）**：`foreground_watcher.dart` 新增 `ScreenStateEvent{screenOn,tsMs}` + `Stream<ScreenStateEvent> get screenEvents`；在既有 `_poll` 的屏幕探测（`_probeScreenOnForBudget`，默认 `dumpsys power`，失败 fail-open=true）后 `_maybeEmitScreen(screenOn)` —— **仅切换时**发（首拍也发以同步初始态，持续同态去重），`dispose()` 关闭控制器。**不新增权限/manifest/原生通路**（复用 `ScreenOnProbe`）。
- **协调器**：`start()` 在 `watcher.start()` 之前订阅 `watcher.screenEvents` → `unawaited(engine.onScreenState(event.screenOn))`；`stop()` 先取消 `_screenSub` 再 dispose watcher/engine。生命周期/fail-closed/有保证还原语义不变。
- **坑（测试）**：`_FakeWatcher` 需 override `screenEvents` 暴露自有 sync 广播控制器 + `emitForeground/emitScreen`；`stop()→watcher.dispose()` 若把屏幕控制器也 close，则 stop 后 emit 会抛 `Cannot add new events after calling close` → 假监视器 dispose **不**关闭 `_screens`（保持可 emit）以证明「stop 后无监听者、引擎不再被驱动」。协调器默认 `debounce=400ms`，测试传 `debounce: Duration.zero` 使事件在同一测试帧收敛；用 `_settle()`（多次 `Future.delayed(Duration.zero)`）冲刷 unawaited 引擎收敛。
- **验证**：`dart analyze lib/` = **0 error**；`flutter test ...{auto_engine,foreground_watcher,coordinator}` = **61 passed**；回归 profile/mode_profiles/store = **67 passed**。证据 `.omo/evidence/task-28-auto-mode.txt`（gitignored）已更新。
- **范围**：仍**未**改 page/引擎/store/control 文件；只动 watcher + coordinator（计划 Refs）。

## Final F3 — release APK 构建（final verification wave）(2026-10-19)
- **命令**：`flutter build apk --release --target-platform android-arm64`，在 repo 根运行。
- **结果**：**PASS**。exit 0；产物 `build/app/outputs/flutter-apk/app-release.apk` = **148653274 bytes (~148.7 MB)**，mtime 16:35:36，sha1 `4fee33f85f095027d3a320e8446f53485929d2ca`。
- **坑（环境性，非源码）**：前两次尝试失败，均源于 `:integration_test` release 依赖解析的间歇性 **JVM-TLS 握手终止**——attempt 2 的签名（`Could not resolve androidx.test:runner:1.2+` / `Remote host terminated the handshake`）与 todo-1 baseline 记录**完全一致**；attempt 1 表现为下游的 `GeneratedPluginRegistrant.java:79 程序包 dev.flutter.plugins.integration_test 不存在`（同一根因：integration_test 类未进 app 编译 classpath）。同窗口 `curl` 同一 Maven Central URL 秒回（HTTP 404）→ 网络本身可达，纯属 Gradle/JVM 侧偶发。第 3 次尝试成功（36.8s）。
- **教训**：此环境的 `:integration_test` 依赖解析会间歇性 TLS 失败；需按 todo-1 的「重试」惯例多试，不要误判为源码回归。**未**改任何产品/测试源码、未 bump 版本、未加依赖、未 push。
- 证据：`.omo/evidence/final-f3.txt`（`.omo/` gitignored；`git add -f` 提交）。

## Batch 2 (partial) — Scene 风格 ring gauge + dashboard hero 组件（未接线）(2026-10-19)
- **只新建 `lib/page/perf/` 本地文件，不接线页面（view.dart 归后续批次）**：`scene_perf_style.dart`（令牌 + 色档→主题色映射）、`scene_ring_gauge.dart`（`SceneRingGauge` + `SceneRingPainter`）、`scene_dashboard_hero.dart`（`SceneDashboardHero`）。**未改** `lib/page/home/**` / `settings` / router / `lib/core/theme/**` / 全局 `ThemeData`；`lib/core/perf/scene_thresholds.dart` 只 import。
- **唯一硬编码色**收敛在 `ScenePerfStyle.accent = Color(0xFFBC8DE4)`（Scene `colors.xml:21 colorAccent`；Material 无对应语义角色）。其余全走 `Theme.of(context).colorScheme`（`error`/`tertiary`/`onSurfaceVariant`/`surfaceContainerHighest`/`secondaryContainer`）。色档映射：负载 normal→accent、high→tertiary、veryHigh→error；温度 normal→accent、mid→tertiary、high/veryHigh→error（= Scene `CpuChartView.kt:177 else accentColor` 语义）。
- **环复刻 Scene 招牌整圆环**：`SceneRingPainter` 从 -90°（正上方）顺时针扫 `fraction` 整圈（`drawArc(rect, -pi/2, 2π·f)`，StrokeCap.round），**非** `GaugeChart` 的 210°/240° 开口弧。`value`+`max` 成对（百分比 `max:100`，0..1 比率 `max:1`）；NaN/±Inf/max≤0 一律钳制为 0，绝不抛。
- **四档按钮接线复用既有路径**：`applyPerfModeToAllProfiles(store, mode)`（`perf_profiles_tile.dart`）+ `commonPerfModeOf(loadAll)` 高亮；store 默认 `ConfigPerfProfileStore`（测试注入 `InMemoryPerfProfileStore`）。能力门禁镜像 `PerfProfilesTile` 语义——**仅显式「无任一可写类别」禁用 + 可见原因；`null`（未探测）不阻断**。返回 `0`=无档案（提示未持久化）、`null`=失败（错误文案），有回调 seam `onModeApplied(mode,count)`。
- **可注入 seam**：`state`（`PerfPageState?`，null→全占位）、`store`、`capabilities`/`capabilityLoader`、`onModeApplied`——widget 测试零真机 / Shizuku / FFI（默认 store 触达 `ConfigStore` 未初始化时 loadAll 内部 try/catch 已兜底，日志可见但不崩）。
- **坑（测试断言）**：`sceneCpuLoadTier` 语义是**严格大于**——85 不越 veryHigh(85) 但 >65 → `high`(tertiary)，不是 accent。写边界断言时按真实比较语义（`>` vs `>=`），别按直觉。
- 验证：`dart analyze lib/` = **0 error**，且 3 新文件无 warning/info；2 测试文件 `dart analyze` = No issues found；`flutter test` 两文件 = **18 passed**（ring 9：渲染/量纲/钳制/传递色 + 阈值映射 group；hero 9：null 降级/全量/环色/能力可用·禁用/应用成功·无档案·失败）。硬编码色 grep 门 = 仅 1 处 accent；`log(` = none。设备未验证。
- 提交：`flock` + 显式 pathspec（只 5 个新文件）；新文件先 `git add` 后方可 pathspec 提交。

## Batch 2 (cont.) — Scene 风格概览接线（hero + rings + FPS 统计 + 设备头）(2026-10-19)
- **接线 `lib/page/perf/view.dart`（概览 tab）**：`SceneDashboardHero` 置为概览 `ListView` **第一项**，传 `state: state`（`ref.watch(perfMonitorProvider)`）与 `capabilityLoader: state.moduleReady ? _loadControlCapabilities : null`。能力 seam 经**注入的** `perfModuleProvider.tunables()` → `perfCapabilityProbeProvider.probe()`，任一失败 → `null`（未知不阻断四档按钮；模块未就绪不探测，避免无谓 Shizuku 命令）。5 段 `AppTabBar` **逐字未动**。
- **FPS 区 Scene 化**：新增顶部**设备信息头**（机型 / 平台 / 系统）+ **MAX/MIN/AVG** 三口径 + **≥45fps 占比** / **≥46℃ 占比**。样本复用 `PerfPageState.fpsHistory`（FPS）与 `thermalMaxHistory`（温度），比率复用 `fps_analysis.dart` 的 `fpsFluencyRatio`/`highTempRatio`（`×100` 成百分比，与报告页同源，**不新增算法**）。**无样本一律「—」**（不臆造 0）。既有三口径列 Key（`perf_fps_app/screen/third_party`）、图表、`perfMetric`、worst frames、重置按钮全部保留。
- **设备信息真实来源（新文件 `lib/page/perf/perf_device_info.dart`）**：首选原生 `perf.device`（`DeviceReport.model/hardware/androidRelease`，与 Scene `device.soc/model/sdk` 对齐），兜底 `device_info_plus` 的 `androidInfo`；任何失败 / 全空 → `null`（UI「—」）。**关键：不改 `PerfPageState` / `logic.dart` 采集主链路**——若把 `module.device()` 塞进 `refresh()` 的 `Future.wait`，既有模块就绪测试的 `_moduleReadyData()` 缺 `perf.device` stub 会令整批刷新失败并翻错误卡（破坏面大）。故用独立 `FutureProvider` 惰性取，失败隔离。
- **扁平密度**：概览各卡改用 `ScenePerfStyle.cardPadding`(12) + `ScenePerfStyle.sectionHeader`(accent 图标 + `titleSmall` 半粗)，移除 `margin: AppSpacing.allLG`（改随主题默认卡距，与 hero 一致）；基线卡自定义表头行替换为 `sectionHeader`。**未改** `scene_ring_gauge.dart`/`scene_dashboard_hero.dart`。
- **测试坑（文本误撞）**：概览现多了 hero + 设备头 + FPS 统计的「—」/「60.0」占位——`perf_monitor_page_test` 的 `find.text('60.0') findsOneWidget` 与 `perf_fps_card_test` 的 `find.text('—') findsNWidgets(2)` 会因新增文本翻车。改法：用 `find.descendant(of: find.byKey('perf_fps_app'/'perf_fps_screen'/...), matching: find.text(...))` **限定到既有列 Key**，既保断言强度又免计数脆弱。`perf_fps_card_test` 空历史 → 统计全「—」（不落 `stats.fps` 兜底），故 test1 的 `'60.0' findsOneWidget` 无需改。
- 新增 `test/page/perf/scene_overview_test.dart`：hero 置顶（`scene_hero_rings` + 4 环）/ 设备头三格（noop 网关 → 全「—」）/ FPS 统计（60.0 / 30.0 / 46.7 / 66.7% / 50.0%，按 Key scope）/ 五段 tab 完整 / 空历史统计降级「—」。假 notifier 直出 `PerfPageState`，零真机。
- 验证：`dart analyze lib/` = **0 error**（727 全 info/warning，`grep -cE '^\s+error -'` = 0；`lib/page/perf/` = No issues found）；`flutter test test/page/perf/` = **119 passed**（含新 2 例）。设备未验证（noop 网关 / 无 Shizuku）。
