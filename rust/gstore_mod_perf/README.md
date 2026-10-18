# gstore_mod_perf

GStore 设备性能监控模块（Phase 1：采集器 + C ABI 模块 + 单测；无 JNI / Dart / UI）。

- **只读**：仅读 `/proc`、`/sys`、`getprop`；不写 sysfs、不需要 root。
- **真实算法**：`/proc/stat` 增量占用率 / `meminfo` 解析 / 各 sysfs 缩放阈值，
  **不复刻**参考 App（`com.jumang.scene`）被丢弃/伪造的随机 CPU%（PERF_SPEC §3.1/§3.2/B2/B3）。
- **依赖最小**：`gstore_contract` + `serde`/`serde_json` + `libc`，直接解析 `/proc`/`/sys`。
- **ABI**：`gstore_contract` v3，模块名 `perf`，注册符号 `gstore_mod_perf_register`。

## 构建

```bash
cd rust/gstore_mod_perf
cargo build                      # 宿主（Linux）调试构建
cargo test                       # 单元 + 集成测试
cargo clippy -- -D warnings
cargo build --release --target aarch64-linux-android   # Android（需 .cargo/config.toml 的 NDK）
```

三个构建脚本已注册本 crate：`build_android_rust.sh`（`MODULES`）、`rust/build_all.sh`、`rust/test_all.sh`。

## C ABI

宿主经 `dlopen` + `dlsym("gstore_mod_perf_register")` 握手，读取 `GStoreModuleApi`
（`abi_version >= 3`，末尾追加字段前向兼容）。导出：`init/create/call/cancel/destroy/shutdown/alloc/free/on_event`。

- `create(config)`：`config` 为 `ModuleContext` JSON（`data_dir`/`cache_dir`/`abi`/`app_version`）。
- `call(instance, method, payload)`：`payload` 为方法 JSON（可空）；成功返回
  `{"ok":true,"data":{...}}`；失败写入结构化错误载荷并返回 `ABI_ERR_DETAIL(-8)`
  （`{status,code,message}`，宿主据此还原 405/422 等）。
- `alloc/free`：宿主用模块 `free` 释放响应缓冲（`libc::malloc/free` 配对）。
- `on_event`：宿主事件下发（Phase 1 仅日志）。
- 采样事件：模块经宿主 `emit_event` 上报 `perf.sample`，载荷为采样快照 JSON
  （宿主负载约定：前 4 字节为事件类型长度，小端）。

## 方法 schema（24 个）

所有实例方法需有效 `instance`（`ping` 除外）。`data` 内单位显式标注（`*_kb`/`*_mhz`/`*_c`/`*_ma`/`*_bytes`/`*_us`/`*_uah`）。

| 方法 | 请求 payload | 成功 `data` 摘要 |
|---|---|---|
| `ping` | — | `{pong:true, module, moduleVersion, apiVersion, minHostAbi, hostAbi, samplerRunning, instanceId?, sampleCount?}` |
| `perf.snapshot` | `{include_processes?:bool, process_limit?:int}` | `{ts_ms, cpu, memory, battery, battery_health, thermal, cooling, pressure, gpu, network, storage, device, processes?}` |
| `perf.cpu` | — | `{usage_percent, per_core_usage[], core_count, frequencies_mhz[], governor, available_frequencies_mhz[], max_freq_mhz, min_freq_mhz, loadavg, cores[], available_governors[], freq_residency:[{freq_mhz,ticks}]}` |
| `perf.memory` | — | `{total_kb, free_kb, available_kb, buffers_kb, cached_kb, sreclaimable_kb, shmem_kb, slab_kb, used_kb, used_percent, swap_total_kb, swap_free_kb, swap_used_kb, swap_percent, swap_cached_kb, dirty_kb, zram_total_kb, zram_used_kb, *_human}` |
| `perf.battery` | — | `{present, base_path, capacity_percent, voltage_v, current_ma, temperature_c, status, health, technology, charge_full_uah, charge_full_design_uah, cycle_count}` |
| `perf.battery_health` | — | `{present, base_path, charge_full_uah, charge_full_design_uah, cycle_count, health, status, technology, charge_counter_uah, capacity_percent, voltage_v, temperature_c}` |
| `perf.thermal` | — | `{zone_count, max_temp_c, zones:[{source, zone, kind, temp_c}]}` |
| `perf.cooling` | — | `{count, devices:[{device, type, cur_state, max_state}]}` |
| `perf.tunables` | — | `{cpu_clusters:[{policy, related_cpus[], available_governors[], governor, available_frequencies_mhz[], min_freq_mhz, max_freq_mhz}], cpusets:[{name, cpus, mems}], thermal_zones:[{zone, type, mode}], cooling_devices:[{device, type, cur_state, max_state}], gpu:{available_frequencies_mhz[], freq_source, governor, governor_source, power_levels, power_source}}` |
| `perf.sysfs.read` | `{path:string}`（**必需**） | `{path, value:string\|null, exists:bool}`；`path` 不在白名单（`/etc/passwd`、`/data/...`、穿越路径）→ 结构化 `invalid_arg`（**永不返回值**） |
| `perf.pressure` | — | `{cpu:{some,full}, memory:{some,full}, io:{some,full}}`，其中每条记录 `{avg10, avg60, avg300, total_us}`（`some`/`full` 缺失为 `null`） |
| `perf.gpu` | — | `{name, freq_mhz, freq_source, busy_percent, busy_source}` |
| `perf.network` | — | `{rx_bytes, tx_bytes, rx_bytes_per_sec, tx_bytes_per_sec, interfaces:[{name, rx_bytes, tx_bytes, rx_packets, tx_packets, rx_bytes_per_sec, tx_bytes_per_sec, rx_errors, tx_errors, rx_dropped, tx_dropped, rx_fifo, tx_fifo, rx_frame, rx_compressed, tx_compressed, multicast}]}` |
| `perf.storage` | — | `{volumes:[{mount, fs, total_kb, free_kb, used_kb, used_percent}]}` |
| `perf.processes` | `{limit?:int(1..100,默认10), sort?:"cpu"\|"rss"}` | `{total, sort, processes:[{pid, name, cmdline, state, cpu_ticks, cpu_percent, rss_kb, rss_bytes}]}` |
| `perf.parse_app_dumps` | `{package:string(必需), pid?:int, uid?:int, cpuinfo?:string, meminfo?:string, gfxinfo?:string, ps?:string, status?:string, netstats?:string, framestats?:string, batterystats?:string, package_info?:string, smaps?:string, crash_log?:string, anr_log?:string, activity?:string}` | `{package, pid, running, cpu_percent, mem_pss_kb, mem_rss_kb, mem_java_heap_kb, mem_native_heap_kb, mem_private_dirty_kb, frame_count, janky_frames, janky_percent, p50_ms, p90_ms, p95_ms, p99_ms, missed_vsync, high_input_latency, slow_ui_thread, slow_bitmap_uploads, slow_draw, uid, threads, mem_summary{java_heap_kb,native_heap_kb,code_kb,stack_kb,graphics_kb,private_other_kb,system_kb,total_pss_kb}, processes:[{pid,ppid,rss_kb,name}], net:{uid,rx_bytes,tx_bytes}\|null, render:{frame_count,fps,jank_count,avg_total_ms,p50_total_ms,p90_total_ms,p99_total_ms,avg_ui_ms,avg_draw_ms,avg_gpu_ms}\|null, power:{mah,wake_lock_ms,mobile_radio_mah,wifi_mah,screen_mah,cpu_mah}\|null, app_info:{version_name,version_code,target_sdk,min_sdk,first_install,last_update,code_path,data_dir,is_system,enabled,requested_permissions,granted_permissions,activity_count,service_count,receiver_count,provider_count}\|null, smaps:{pss_kb,rss_kb,shared_clean_kb,shared_dirty_kb,private_clean_kb,private_dirty_kb}\|null, crashes:{crash_count,anr_count,last_crash,last_anr,recent:[{kind,time,summary}]}\|null, foreground:{is_foreground}\|null, wake_locks:[{name,ms}]}` |
| `perf.parse_startup` | `{output:string, mode?:"cold"\|"warm"(默认"warm")}` | `{status:"ok"\|"Error", activity:string\|null, this_time_ms:int\|null, total_time_ms:int\|null, wait_time_ms:int\|null, mode:"cold"\|"warm"}` |
| `perf.foreground` | `{activity:string}`（`dumpsys activity activities` 原文） | `{package:string\|null}`；从 resumed 行（`mResumedActivity`/`topResumedActivity`/`ResumedActivity`）的 `<pkg>/<activity>` 抽取当前前台包名；无 resumed 行/歧义 → `null`（**永不报错、永不猜测**，仅回传包名） |
| `perf.device` | — | `{kernel_version, hardware, cpu_name, model, android_release, board_platform, core_count, loadavg, os_release}` |
| `perf.start` | `{interval_ms?:int(默认2000, 夹取200..600000)}` | `{running, interval_ms, instanceId}` |
| `perf.stop` | — | `{running:false, was_running}` |
| `perf.status` | — | `{running, interval_ms, instanceId, running_count}` |
| `perf.history` | `{limit?:int(默认全部, 上限300)}` | `{count, capacity, samples:[{seq, ts_ms, data}]}` |
| `perf.reset` | — | `{ok:true, ts_ms}`（清空采样环与全部增量基线） |

## 采集算法与单位

| 采集器 | 数据源 | 算法 / 单位 |
|---|---|---|
| CPU 占用 | `/proc/stat` | `total=Σfields[1..]`，`idle=fields[4]`，`usage%=100-Δidle*100/Δtotal`，clamp 0..100。**由调用方保存上次样本，两次调用间取增量，绝不 sleep** |
| CPU 频率 | `cpu{i}/cpufreq/scaling_cur_freq` → `cpuinfo_cur_freq` → `/proc/cpuinfo` `cpu MHz` | kHz→MHz ÷1000；另读 `scaling_governor`、`scaling_available_governors`、`available_frequencies`、`cpuinfo_max/min_freq`、`/proc/loadavg` |
| CPU 频率驻留 | `cpu{i}/cpufreq/stats/time_in_state` | 每行 `freq_khz ticks`；跨核按频率**求和** ticks → `freq_residency:[{freq_mhz,ticks}]`（`ticks` 单位由内核定义，只有相对分布有意义；缺失 → `[]`） |
| 内存 | `/proc/meminfo` | 原始 KiB；`used = MemTotal - MemAvailable`（缺失回退 MemFree）；含 Buffers/Cached/SReclaimable/Shmem/Slab/Swap*/Dirty/Zram* |
| 电池 | `/sys/class/power_supply/{battery,\*}` | 电流 µA→mA **仅 `|v|>10000` ÷1000**；电压 µV→V（`>1e6→/1e6`，`>1000→/1000`）；温度 0.1°C ÷10；无电池返回 `present:false` |
| 电池健康 | `/sys/class/power_supply/{battery,bms,\*}` | 满充/设计容量 µAh、循环次数、`charge_counter`（µAh）、health/status/technology、容量%；电压/温度复用 battery 缩放；无电池 → `present:false` |
| 热区 | `thermal_zone*/{type,temp}` + `hwmon*/temp*_input` | 枚举全部热区；`|raw|>1000` 视为毫摄氏度 ÷1000 |
| 散热设备 | `/sys/class/thermal/cooling_device*/{type,cur_state,max_state}` | 枚举全部 `cooling_device*`；无设备 → `count:0, devices:[]` |
| 可控面枚举 | `cpufreq/policy*`、`/dev/cpuset/*`、`thermal_zone*/{type,mode}`、`cooling_device*`、GPU `available_frequencies`/`governor`/`num_pwrlevels` | **只读**枚举可控旋钮与取值范围：每策略簇 `related_cpus`/governors/freqs/governor/min/max；cpuset `cpus`/`mems`；热区 `mode`；散热 `cur_state`；GPU 频率（路径表 + `gpu.rs` 缩放）与功耗档位。节点缺失 → `[]`/`null`，绝不写盘 |
| 白名单单路径读取 | `sysfs_read::SYSFS_ALLOWLIST`（cpufreq `scaling_*`/`cpuinfo_*`、cpuset `cpus`/`mems`、thermal `temp`/`mode`、GPU 频率/governor/功耗档位） | **只读** `perf.sysfs.read` 的采集器：`*` 单段通配精确匹配；非白名单/穿越路径 → `invalid_arg`；节点缺失 → `exists:false,value:null`。以 App 进程 uid 读取，非 world-readable 节点须经特权 shell 回读 |
| 前台包名抽取 | `app_activity::parse_current_package`（`dumpsys activity activities` 原文） | **只读、纯解析**：扫描含 resumed 标记（`mResumedActivity`/`topResumedActivity`/`ResumedActivity`）的行，取 `<pkg>/<activity>` 的 `<pkg>`（兼容 `u0` 前缀与 `pkg/pkg.Act` 两种形态）。无 resumed 行/`null`/多个不同包（歧义）→ `null`；仅回传包名，不保留活动全文 |
| PSI 压力 | `/proc/pressure/{cpu,memory,io}` | 逐行 `some`/`full avg10=.. avg60=.. avg300=.. total=<us>`；`total` 微秒（内核定义）；cpu 通常只有 `some`；文件缺失 → 该资源 `some`/`full` 为 `null` |
| 存储 | `/proc/mounts` + `libc::statvfs` | 仅真实 fs，跳过 proc/sysfs/tmpfs/devpts/cgroup/overlay 等伪 fs；按挂载点去重；`total=f_blocks·frsize/1024`、`free=f_bavail·…`、`used=(f_blocks−f_bfree)·…`、`used_percent=used/total×100` |
| GPU | kgsl/devfreq/kernel/mali 多路径 | freq 列表 A（Hz→÷1e6）+ 列表 B（`>1e6→/1e6`，`>1000→/1000`）；busy 去 `%`；name 走 `getprop ro.hardware.gpu\|ro.board.platform\|ro.hardware.vulkan` |
| 网络 | `/proc/net/dev` | 解析各接口 rx/tx 字节 **与全部 16 列**（errs/drop/fifo/frame/compressed/multicast）；由上次样本 + 时间差算 `*_bytes_per_sec`（计数器回绕用 saturating_sub） |
| 进程 | `/proc/[pid]/{stat,statm,cmdline}` | `comm` 用首 `(`/末 `)` 夹取；utime/stime 增量 ÷CLK_TCK ÷Δt ×100；RSS=statm 常驻页×页大小；消失/竞态一律跳过 |
| 设备 | `/proc/version`、`/proc/cpuinfo`、`/proc/loadavg`、`getprop`、`/etc/os-release` | SoC 关键字表→可读名（Snapdragon/联发科/Exynos/麒麟） |

## 第三方应用解析（`perf.parse_app_dumps`）

**纯解析**：输入是宿主经 Shizuku 采集到的原始 `dumpsys` 文本；本方法不启动 shell、
不做 JNI、不需要特权。解析不到的字段一律 `null`，绝不 panic。仅当 `package` 缺失/空时
返回 `invalid_arg`。`running = 任一指标解析成功 或 pid>0`。**不计算 FPS**（FPS 由调用方用
两次 `frame_count` 增量 + 时间差推导）。

| 来源 | 关键行 | 说明 |
|---|---|---|
| `cpuinfo` | `([0-9.]+)%\s+\+?(\d+)/(\S+):` | 包名 == `package` 或以 `package:` 开头的子进程（如 `com.x:service`）**求和**；无包名匹配时回退按 `pid` 匹配 |
| `meminfo` | `TOTAL PSS:`/`TOTAL RSS:`（含千分位 `1,234,567`） | 无 PSS 时回退取 `TOTAL` 数据行首个整数（旧式格式）；附带 `Java Heap:`/`Native Heap:`/`Private Dirty:`；`** MEMINFO in pid N` 可补 pid |
| `meminfo` (§App Summary) | `Java Heap:`/`Native Heap:`/`Code:`/`Stack:`/`Graphics:`/`Private Other:`/`System:` | 合并为 `mem_summary` 对象（各字段独立 `null`）；`total_pss_kb` 取上面的 `TOTAL PSS:`/`TOTAL` 结果 |
| `gfxinfo` | `Total frames rendered` / `Janky frames` / `NNth percentile` / `Number *` | summary（非 framestats）；missed vsync、high input latency、slow UI/bitmap/draw |
| `ps`（`ps -A`） | `USER PID PPID VSZ RSS WCHAN ADDR S NAME` 默认列 | 保留 `NAME == package` 或以 `package:` 开头的行 → `processes`（`pid`/`ppid`/`rss_kb`；Android `ps` RSS 单位 KB）；跳过表头与不可解析行，无匹配 → `[]` |
| `status`（`/proc/<pid>/status`） | `Threads:\s*(\d+)` | → `threads`；另外 `Uid:` 首个整数作为 uid 回退（请求未带 `uid` 时） |
| `netstats`（`dumpsys netstats detail`） | `uid=(\d+)` 分块 + 后续 `rb=`/`tb=` | 累加 `uid == 请求 uid` 的各块 → `net{uid,rx_bytes,tx_bytes}`（去千分位）；格式不符/无该 uid → `null`（UI 显示「不可用」）；**请求未带 `uid` 时不做 net 匹配** |
| `framestats`（`dumpsys gfxinfo <pkg> framestats`） | `---PROFILEDATA---` 之间的逐帧 CSV | 首行表头，**按表头名**（大小写不敏感）定位列，兼容各 Android 版本列顺序差异。时间戳纳秒→毫秒。跳过 `FrameCompleted==0`（未完成帧）及源列为 0/缺失的行。`total=(FrameCompleted-IntendedVsync)`、`ui=(DrawStart-IntendedVsync)`、`draw=(IssueDrawCommandsStart-DrawStart)`、`gpu=(FrameCompleted-SyncStart)`；`avg_*` 为均值，`p50/p90/p99_total_ms` 为**最近秩**百分位，`jank_count=total>2×16.666` 的帧数，`fps=(n-1)*1e9/(last-first IntendedVsync)`（<2 帧或跨度≤0 → `0`）。无 PROFILEDATA 区域/无 FrameCompleted 列/无有效帧 → `render:null` |
| `batterystats`（`dumpsys batterystats --charged <pkg>`） | `Estimated power use (mAh):` / `Uid u0aXXX:` / `Wake lock ...:` / `Mobile radio:`/`Wifi:`/`Screen:`/`CPU:` | **best-effort**：`mah` 取 `Estimated power use (mAh):` 后**紧邻**数字，否则按请求 `uid` 匹配 `Uid u0aXXX:`；`wake_lock_ms` 累加所有 `Wake lock ...: (Xh )?(Xm )?(Xs )?` 行（`ms` 优先判定），无个体行时回退 `Total time ... wake lock` 行；组件 mAh 各自独立 `null`。识别不到任何字段 → `power:null` |
| `package_info`（`dumpsys package <pkg>`） | `versionName=` / `versionCode=` / `targetSdk=` / `minSdk=` / `firstInstallTime=` / `lastUpdateTime=` / `codePath=` / `dataDir=` / `flags=[...]` / `enabled=` | → `app_info`（时间字段**按原字符串**保留）。`is_system` = `flags=[...]` 含精确 token `SYSTEM`；`enabled` = 优先 `flags` 含 `DISABLED` → `false`，否则 `enabled=`（`true`/`false` 或整数 0/1 启用、≥2 停用）；`requested_permissions` = `requested permissions:` 缩进块行数；`granted_permissions` = 全文中 `granted=true` 行数；组件计数 = `Activity/Service/Receiver/Provider Resolver Table:`（0 缩进段）中含 `package/` 的行数（**段缺失 → null**）。无任何可识别字段 → `app_info:null` |
| `smaps`（`cat /proc/<pid>/smaps_rollup`，可多进程块拼接） | `Rss:` / `Pss:` / `Shared_Clean:` / `Shared_Dirty:` / `Private_Clean:` / `Private_Dirty:`（`kB`） | **跨块求和**；`Pss_Dirty`/`Rss_Anon` 等带下划线变体不误配（标签含冒号精确匹配）。无任何字段 → `smaps:null` |
| `crash_log`/`anr_log`（`dumpsys dropbox --print data_app_crash` / `data_app_anr`） | 时间戳行 `YYYY-MM-DD HH:MM:SS` 分隔记录；正文 `Process:` / `Cmd line:` | 按时间戳切分记录；仅统计正文含目标 `package` 的记录（正文指名别的包 → 排除；正文无包名标识 → best-effort 计入）。`last_crash`/`last_anr` = 匹配记录最新时间戳字符串；`recent` = 最新 5 条 `{kind:"crash"\|"anr", time, summary}`，`summary` 取正文含 `Process:`/`Caused by`/`Exception` 的行（否则首个非空行）截断 ~120 字符。两路均无记录 → `crashes:null` |
| `activity`（`dumpsys activity activities`） | `mResumedActivity` / `topResumedActivity` / `ResumedActivity` 行 | `is_foreground` = 存在 resumed 行且其中提及 `package`；存在 resumed 行但为其它包 → `false`；无 resumed 行（无法判定）→ `foreground:null` |
| `wake_locks`（复用请求中同一 `batterystats`，**无新输入**） | `Wake lock <name>: <duration>` | 逐条列 `{name, ms}`（名称保留原样，可含 `:` 子进程前缀；时长复用 `h/m/s/ms` 扫描器）。无个体行 → `[]` |

`running = 任一既有指标解析成功 或 pid>0`（`pid` 仍由显式 `pid` → `meminfo` → `cpuinfo` → `ps` 首个匹配进程 依次补出）。
`uid` 为请求 `uid`，缺省时回退 `status` 的 `Uid:`。新增字段全部**可为 `null`**，解析不到不报错。
`render` 段的 `fps` 直接来自 `framestats` 的 `IntendedVsync` 间隔（交付帧率）；`gfxinfo` summary 路径
仍**不计算 FPS**，由调用方对两次 `frame_count` 取增量推导。

## 应用启动耗时解析（`perf.parse_startup`）

**纯解析**：输入是宿主经 Shizuku 执行 `am start -W [-S] -n <pkg>/<activity>` 捕获到的 stdout；
本方法不启动 shell、不做 JNI、不需要特权。解析不到的字段一律 `null`，绝不 panic。
`output` 可缺省（→ 全 `null`），`mode` 缺省 `"warm"`，仅大小写不敏感的 `cold` 归一为 `"cold"`。

| 关键行 | 说明 |
|---|---|
| `Status: ok` | 存在 `Error:` 行时 `status="Error"`（优先于 `Status:` 且与行序无关）；否则取 `Status:` 值，缺省 `"ok"` |
| `Activity: com.x/.MainActivity` | → `activity`（缺失/空 → `null`） |
| `ThisTime:` / `TotalTime:` / `WaitTime:` | 标签后**首个整数**（容忍尾随文本如 `250 ms`）→ `*_ms`；不可解析 → `null` |
| `Error: ...` | 任意 `Error:` 行 → `status="Error"` |
| `LaunchState:` / `Warning:` / `Starting:` | 原样容忍/忽略（`mode` 回显请求而非从 `LaunchState:` 推断） |

`am` 失败时的 `Warning: Activity not started, intent has been delivered to currently running top-most instance.`
**不**置 `Error`。同名字段取**首个**命中行。数值字段可为 `0`（显式 0 不被当作缺失）。

## 采样器

`perf.start` 启动单驱动后台线程（模式参照 `gstore_mod_proxy/src/stats_monitor.rs`）：
按间隔（默认 2000 ms）采样 → 写入实例内采样环（容量 300）→ 经宿主 `emit_event`
上报 `perf.sample`。`perf.stop` 发送信号并 join；`destroy`/`shutdown` 亦停止采样器，
保证线程不泄漏。

## 目录

```
src/
├── lib.rs          # C ABI 导出（register/create/call/cancel/destroy/shutdown/alloc/free/on_event）
├── methods.rs      # 方法分发表（24 个）
├── snapshot.rs     # 采集编排 + 增量基线更新
├── sampler.rs      # 后台采样线程 + 采样环
├── state.rs        # 实例状态、宿主回调注册表
├── abi_io.rs       # 输出缓冲 / 结构化错误 / 成功信封
└── collectors/     # 纯逻辑采集器（cpu/memory/battery/battery_health/thermal/cooling/tunables/sysfs_read/pressure/gpu/network/storage/processes/device/app_dumps/app_render/app_power/app_info/app_smaps/app_crash/app_activity/app_startup/util）
tests/
└── abi_integration.rs   # 真实 C ABI 端到端测试
```
