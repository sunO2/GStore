# 18 · 性能监控：Scene 逆向对比与增强

> 本文档是 `scene-perf-reverse-gstore` 计划的 Wave 2 交付物（todo 8）。
> 目的：把对参考 App **Scene**（`com.jumang.scene`）的逆向结论与 GStore 现有性能栈做逐项对照，
> 明确**监控类**与**控制 / 调优类**差距，给出映射到「姿态 (b)」（Shizuku-shell 可写、无 root）
> 的优先级建议，并给出可行性 / 风险边界。
>
> 两个 Wave 1 产物的**对照基线**（按路径交叉引用）：
> - Scene 8 轴特性目录：`.omo/evidence/scene-perf-reverse-gstore/scene-feature-catalog.md`
> - GStore 性能能力清单：`.omo/evidence/scene-perf-reverse-gstore/gstore-perf-inventory.md`
>
> **立场（不可谈判）**：GStore 性能栈为**只读 / 无 root**（`rust/gstore_mod_perf/README.md:5`）。
> 本文只**提出**增强方向，**不声称**任何控制能力已可用——所有控制类可行性由能力探针
> （`lib/core/perf/perf_capability_probe.dart`，todo 15）逐节点定值。**本构建环境无 Shizuku 设备**，
> 故设备依赖项一律记 `unavailable-on-shell`、基础设施项记 `环境受限·待真机确认`（详 §四 取值说明与 §5.5）。

---

## 一、Scene APK 身份、哈希与逆向方法

### 1.1 身份与可信基线

| 项 | 值 | 证据 |
|---|---|---|
| 包名 | `com.jumang.scene` | `.omo/evidence/scene-perf-reverse-gstore/task-1-apk-identity.txt:10` |
| 版本 | `versionName=9.1` / `versionCode=91` | `task-1-apk-identity.txt:11-12` |
| SDK | `minSdk=24` / `targetSdk=33` | `task-1-apk-identity.txt:13-14` |
| sha256 | `76ee6c66f0c2bcf1ae4b53485a1cb2afcbe417ea1311ca6cbb06f3f564c7f1fe` | `task-1-apk-identity.txt:9` |
| 字节数 | `27003307`（`Zip archive data`） | `task-1-apk-identity.txt:7-8` |
| 取证源 | `local-fallback`（sha256 门槛校验 MATCH） | `task-1-apk-identity.txt:1,5` |
| 打包器 | **无 packer / 无 protector**（APKiD 3.1.0） | `.omo/evidence/scene-perf-reverse-gstore/apkid.txt:9,13` |
| 性能相关原生库 | **无** | `.omo/evidence/scene-perf-reverse-gstore/native-libs.txt:64` |

身份由三路独立证据互相印证（`task-1-apk-identity.txt:15-18`）：aapt2 `dump badging`、
androguard `APK(...)`、以及同 sha256 的已解码 manifest；三者对
`package / versionName / versionCode / minSdk / targetSdk` 完全一致。

> 注意：本仓库的 `AGENTS.md` 只记录整数文档编号约定（`document/development/NN-标题.md`）；
> 现有最大编号为 `17-代理内核与VPN.md`，故本文使用 `18`。

### 1.2 逆向方法（RE methodology）

1. **静态身份**：aapt2（`/home/hezhihu89/android-sdk/build-tools/35.0.0/aapt2 dump badging`）
   + androguard 交叉核验（`task-1-apk-identity.txt:16-17`）。
2. **Manifest / 资源**：aapt2 `dump xmltree --file AndroidManifest.xml` 产出
   `.omo/evidence/scene-perf-reverse-gstore/manifest-summary.md`（逐 `<service>` / 权限 / 组件枚举）。
3. **DEX 反编译**：jadx（REA 固定版 `jadx-headless-mcp-0.7.1-all.jar`，JDK 17）产出
   `/tmp/opencode/rea-work/jadx-out/sources/`（9544 类，34 处反编译错误），
   以**字面量 `grep -rn -F`** 采摘性能词汇，结论见
   `.omo/evidence/scene-perf-reverse-gstore/dex-evidence.md`。
   由于 **无 packer**（`apkid.txt:73-77`），DEX 字符串证据在打包层面**未被遮蔽**，可信。
4. **原生库普查**：`unzip -l 'lib/*'` + 只读 `strings -a` 扫描性能词汇，
   结论见 `native-libs.txt`（20 个 `.so` / 3 ABI，**零命中**真实 sysfs/proc 词汇）。
5. **只读约束**：全过程未 patch / 未修改任何 `.so`，`scene.apk` 的 sha256 保持不变
   （`native-libs.txt` 末段；`task-1-apk-identity.txt:9`）。

> **关键结论（贯穿全文）**：Scene 展示的 **CPU% 是伪造的**
> ——`SystemInfoUtil.java:100` 用 `coerceIn(... + random(-5,5), 30, 50)` 夹取随机值，
> 真算法（`/proc/stat` 双采样增量）虽在 `ClassFragment.java:194-198` 存在却被回退分支破坏
> （`dex-evidence.md:30-31`）。**GStore 采用真实 `/proc/stat` 增量算法**
> （`rust/gstore_mod_perf/README.md:69`），不复刻该伪造。

---

## 二、8 轴功能对照矩阵

### 2.0 8 轴索引

本矩阵覆盖 `scene-feature-catalog.md` 的 8 个轴（英文轴名与目录一致）：

#### 轴 1 · real-time metrics（实时指标）
实时 CPU / GPU / 温度 / 内存 / 电池的读取与展示。

#### 轴 2 · overlay HUD（悬浮窗）
系统级悬浮窗展示能力的权限与实现。

#### 轴 3 · per-app performance profiles（每应用性能档）
按包名绑定 / 应用的性能档位（governor / cpuset 等）。

#### 轴 4 · historical logging（历史记录）
时间序列的会话内环与跨会话持久化。

#### 轴 5 · third-party + foreground monitoring（第三方 / 前台监控）
逐第三方应用的 CPU / 内存 / 帧 / 前后台判定。

#### 轴 6 · privileges + sysfs（特权与 sysfs）
root / Shizuku-shell / sysfs 读写的特权模型。

#### 轴 7 · export（导出）
性能数据的导出 / 分享。

#### 轴 8 · versions + permissions（版本与权限）
身份、哈希、权限清单、打包 / 库结论。

### 2.1 对照矩阵总表

**列定义**：
- **Scene**：该能力在 `com.jumang.scene` v9.1 中的现状（`有` / `无` / `无核验（降级）`）。
  `无核验（降级）`＝本次 DEX 扫描词汇表未覆盖该能力，**不主张**任何 Scene 结论；
- **GStore**：该能力在当前 GStore 性能栈中的现状（`有` / `无`）；
- **有·无·部分**（对比结论）：`有`＝双方均具备；`无`＝双方均缺失；
  `部分`＝仅一方具备实现不完整；
- **证据**：每行**必须**给出 `file:line` / 字面量 / 路径 token。`file:line` 若在 `sources/`
  前缀缺省，均相对 jadx 树根（`dex-evidence.md:5-9`）；`manifest-summary.md` / `apkid.txt` /
  `native-libs.txt` / `scene-feature-catalog.md` / `gstore-perf-inventory.md` 为本会话 Wave 1 产物。

<!-- MATRIX:BEGIN -->
| 能力 | Scene | GStore | 有·无·部分 | 证据 |
|---|---|---|---|---|
| 实时指标 · CPU 总占用（真实算法） | 有（显示值伪造） | 有（真实） | 部分 | `SystemInfoUtil.java:100`（`coerceIn(...random(-5,5),30,50)`）；`rust/gstore_mod_perf/README.md:69` |
| 实时指标 · 每核当前频率 | 有 | 有 | 有 | `SystemInfoUtil.java:199,203`；`rust/gstore_mod_perf/README.md:70` |
| 实时指标 · CPU 核心数 | 有 | 有 | 有 | `ProcessorInfoActivity.java:84`；`rust/gstore_mod_perf/README.md:45` |
| 实时指标 · CPU governor 读取 | 无 | 有 | 部分 | `dex-evidence.md:97`（governor 未在 DEX）；`rust/gstore_mod_perf/README.md:70` |
| 实时指标 · CPU 可用 governor/频率枚举 | 无 | 有 | 部分 | `dex-evidence.md:97`；`rust/gstore_mod_perf/README.md:45` |
| 实时指标 · GPU 当前频率 | 有 | 有 | 有 | `ClassFragment.java:230`；`rust/gstore_mod_perf/README.md:79` |
| 实时指标 · GPU 忙率 | 有 | 有 | 有 | `ClassFragment.java:827`；`rust/gstore_mod_perf/README.md:79` |
| 实时指标 · GPU 名称 | 有 | 有 | 有 | `ClassFragment.java:811`（getprop）；`rust/gstore_mod_perf/README.md:79` |
| 实时指标 · 内存总量/可用 | 有 | 有 | 有 | `SystemInfoUtil.java:292,431`；`rust/gstore_mod_perf/README.md:72` |
| 实时指标 · 电池电流/容量/电压 | 有 | 有 | 有 | `SystemInfoUtil.java:213`；`ClassFragment.java:643-644`；`rust/gstore_mod_perf/README.md:73` |
| 实时指标 · 电池健康（满充/设计容量/循环） | 无 | 有 | 部分 | `dex-evidence.md:66-75`（无 cycle / 设计容量）；`rust/gstore_mod_perf/README.md:74` |
| 实时指标 · 热区温度 | 有 | 有 | 有 | `MajorActivity.java:287`；`rust/gstore_mod_perf/README.md:75` |
| 实时指标 · 散热设备 cooling_device | 无 | 有 | 部分 | `dex-evidence.md:95`（仅 thermal 配置文件，非 cooling_device）；`rust/gstore_mod_perf/README.md:76` |
| 实时指标 · PSI 压力 | 无核验（降级） | 有 | 部分 | `dex-evidence.md:86-106`（扫描词表未含 PSI）；`rust/gstore_mod_perf/README.md:77` |
| 实时指标 · 存储卷 | 无核验（降级） | 有 | 部分 | `dex-evidence.md:86-106`（扫描词表未含 storage）；`rust/gstore_mod_perf/README.md:78` |
| 实时指标 · 网络字节/速率 | 无核验（降级） | 有 | 部分 | `dex-evidence.md:86-106`（扫描词表未含网络）；`rust/gstore_mod_perf/README.md:80` |
| 实时指标 · 进程列表 | 无核验（降级） | 有 | 部分 | `dex-evidence.md:86-106`；`rust/gstore_mod_perf/README.md:81` |
| 实时指标 · FPS / 帧时序（自身应用） | 无 | 有 | 部分 | `dex-evidence.md:79-84`（DEX 0 命中 `fps/vsync/framestats`）；`lib/page/perf/view.dart:26` |
| 实时指标 · 崩溃 / ANR 记录 | 无核验（降级） | 有 | 部分 | `dex-evidence.md:86-106`；`rust/gstore_mod_perf/README.md:104` |
| third-party · 第三方逐应用指标（CPU/PSS/jank/FPS） | 无 | 有 | 部分 | `dex-evidence.md:90-91`（无 `dumpsys`）+ `:87`（无 am/pm）；`rust/gstore_mod_perf/README.md:84-111` |
| third-party · 应用启动耗时 | 无核验（降级） | 有 | 部分 | `dex-evidence.md:91`（无 `am start`）；`rust/gstore_mod_perf/README.md:113-128` |
| overlay HUD · 系统悬浮窗 | 有 | 有 | 有 | `manifest-summary.md:35`（`SYSTEM_ALERT_WINDOW`）；`PerfOverlayService.kt:63` |
| historical logging · 会话内历史环 | 有（内存） | 有（持久化） | 有 | `ChargeStatisticsActivity.java:43,209-212`（size>20 丢弃）；`rust/gstore_mod_perf/README.md:130-135` |
| historical logging · 跨会话持久化 | 无 | 有 | 部分 | `scene-feature-catalog.md:72`（仅进程内 `List`，无持久化）；`lib/core/perf/perf_history_store.dart:98` |
| export · 性能数据导出（报告） | 无 | 有 | 部分 | `scene-feature-catalog.md:116`（`\.csv|export|导出` 0 命中）；`lib/core/perf/perf_export_service.dart:97` |
| 阈值告警 / 通知 | 无核验（降级） | 有 | 部分 | `dex-evidence.md:86-106`；`lib/page/perf/third_party_section.dart:862` |
| Agent 只读性能工具 | 无 | 有 | 部分 | `scene-feature-catalog.md:104`（`shizuku|rikka` 0 命中）；`lib/core/agent/tools/perf_tools.dart:40,56,77` |
| privileges · 无 root / 无 su 立场 | 否（root exec） | 是 | 部分 | `ThermalControlActivity.java:293`（`Runtime.getRuntime().exec(bg.y)`）；`rust/gstore_mod_perf/README.md:5` |
| 控制/调优 · CPU governor 写入 | 无 | 无 | 无 | `dex-evidence.md:97`；`gstore-perf-inventory.md:174`（C1） |
| 控制/调优 · CPU 频率上下限写入 | 无 | 无 | 无 | `dex-evidence.md:97`；`gstore-perf-inventory.md:175`（C2） |
| 控制/调优 · GPU 频率 / 功率模式写入 | 无 | 无 | 无 | `dex-evidence.md:37-39`（仅读）；`gstore-perf-inventory.md:176`（C3） |
| 控制/调优 · cpuset / 亲和性 | 无 | 无 | 无 | `dex-evidence.md:98`；`gstore-perf-inventory.md:177`（C4） |
| 控制/调优 · 温控阈值 / 开关写入 | 有（仅 root） | 无 | 部分 | `ThermalControlActivity.java:230-233,293`；`gstore-perf-inventory.md:178`（C5） |
| 控制/调优 · 每应用性能档（profiles） | 部分（web 来源） | 无 | 部分 | `scene-feature-catalog.md:61`（`github.com/helloklf/vtools`，secondary）；`gstore-perf-inventory.md:179`（C6） |
| 控制/调优 · 通用 sysfs 写入原语 | 有（仅 root） | 无 | 部分 | `ThermalControlActivity.java:293`；`gstore-perf-inventory.md:180`（C7） |
| 控制/调优 · root / su / remount | 有 | 无（禁止） | 部分 | `ThermalControlActivity.java:293`；`gstore-perf-inventory.md:181`（C8） |
| 控制/调优 · 重启设备 | 有（`REBOOT` 权限） | 无 | 部分 | `manifest-summary.md:22` |
| 版本/权限 · 无 packer / 无 perf 原生库 | 无 | 无 | 无 | `apkid.txt:9`；`native-libs.txt:64` |
<!-- MATRIX:END -->

> **矩阵自证**：行数（不含表头与分隔行）见 §六 QA 断言，`>= 20`。
> 标注 `无核验（降级）` 的行已在 §三 与 `task-8-report.txt` 中记录（失败 QA 路径）。

---

## 三、差距清单（监控类 ⇄ 控制 / 调优类）

> 依据：`gstore-perf-inventory.md` §8 与 `scene-feature-catalog.md`。
> 本清单**分离**两类差距。

### 3.1 监控类差距（monitoring）

Scene 与 GStore 在**监控**维度的对照结论：**GStore 现栈为 Scene 的超集**，
Scene 的多数监控项（甚至 CPU% 本身）弱于或劣于 GStore。仅列出有意义的对照项：

| 差距 ID | 描述 | Scene | GStore | 结论 / 处理 |
|---|---|---|---|---|
| MG1 | 厂商化宽回退路径（13 路热区 / 多厂商 GPU 路径） | 有 | 有（多路径） | 已闭合（`MajorActivity.java:287`；`README.md:75`） |
| MG2 | 会话内时间序列环 | 有（20 点） | 有（容量 300） | GStore 领先（`ChargeStatisticsActivity.java:209-212`；`README.md:130-135`） |
| MG3 | 跨会话持久化历史 | 无 | 有 | GStore 领先（`scene-feature-catalog.md:72`；`perf_history_store.dart:98`） |
| MG4 | 性能数据导出 | 无 | 有 | GStore 领先（`scene-feature-catalog.md:116`；`perf_export_service.dart:97`） |
| MG5 | 真实 CPU% 算法 | 伪造 | 真实 | GStore 领先（`dex-evidence.md:30-31`；`README.md:69`） |
| MG6 | 第三方逐应用解析（CPU/PSS/jank/FPS） | 无 | 有 | GStore 领先（`dex-evidence.md:90-91`；`README.md:84-111`） |
| MG7 | Agent 只读性能工具 | 无 | 有 | GStore 领先（`scene-feature-catalog.md:104`；`perf_tools.dart:40,56,77`） |

**监控类结论**：**无阻断性监控缺口**。GStore 已覆盖并超越 Scene 的监控面；
可选的监控类增强仅为「非高通 / 非 Mali 平台的探针扩展」，非本计划阻断项。

### 3.2 控制 / 调优差距（control / tuning）——姿态 (b) 目标

> 来源：`gstore-perf-inventory.md` §8（C1–C8，**全部 ABSENT**；`gstore-perf-inventory.md:160-181`）。
> 这些能力在 GStore 性能栈中**没有任何写入路径**（既不是「部分实现」也不是「未测试」）。

| 差距 ID | 能力（轴） | 现状 | 证据 |
|---|---|---|---|
| CG-CPU-1 | CPU governor 写入（`scaling_governor`） | **ABSENT** | `gstore-perf-inventory.md:174` |
| CG-CPU-2 | CPU 频率上限 / 下限写入（`scaling_max_freq` / `scaling_min_freq`） | **ABSENT** | `gstore-perf-inventory.md:175` |
| CG-GPU-1 | GPU 频率 / 功率模式写入 | **ABSENT** | `gstore-perf-inventory.md:176` |
| CG-CPUSET-1 | cpuset / 进程亲和性绑定 | **ABSENT** | `gstore-perf-inventory.md:177` |
| CG-THERMAL-1 | 温控开关 / thermal 阈值调整 | **ABSENT** | `gstore-perf-inventory.md:178` |
| CG-PROFILE-1 | 每应用性能档（per-app profiles） | **ABSENT** | `gstore-perf-inventory.md:179` |
| CG-SYSFS-1 | 通用 sysfs 写入 / shell 写入原语 | **ABSENT** | `gstore-perf-inventory.md:180` |
| CG-ROOT-1 | root / `su` / remount / SELinux 绕过 | **ABSENT（禁止）** | `gstore-perf-inventory.md:181` |

**控制 / 调优结论**：GStore 现栈 = **纯监控（monitoring-only）**。CPU / GPU / cpuset / thermal /
per-app-profiles **五类控制能力全部缺失**，即**姿态 (b)** 所要填充的缺口。
任何增强方案必须经**能力探针**（capability-probe）按 Shizuku-shell 可写性逐项验证，
并以「**优雅降级 + fail-closed**」为前置（`gstore-perf-inventory.md:183-185`）。

> **注意范围 / 风险边界**：Scene 自身用的是 **root/exec 写路径**
> （`ThermalControlActivity.java:293`），**不是** Shizuku-shell。因此 Scene 的「可写」
> **不能**作为 GStore 在 uid 2000 下可写的证据——这正是所有控制类可行性必须由**真机**能力探针
> 逐节点验证、而**本构建环境**（无 Shizuku 设备）一律记 `unavailable-on-shell` 的原因（详 §5.5）。

---

## 四、优先级建议（映射姿态 (b)）

> **可行性列取值**（由能力探针 todo 15 的输出定值，todo 38 最终化）：
> `confirmed`（**仅**当探针给出**真机**正向证据时）| `unavailable-on-shell`（设备依赖的控制项：
> 本环境无 Shizuku 设备，探针**无法**确认可写，一律记此值并按类别 shipped-disabled）|
> `环境受限·待真机确认`（无设备依赖的基础设施项：实现已交付并单测，运行时门控待真机验证）。
>
> **环境限制（本构建环境无 Shizuku 设备）**：`lib/core/perf/perf_capability_probe.dart`
> 的运行时探针在此环境**不可能**对任何节点给出正向可写判定（`test -w` 仅在真机 uid 2000
> shell 下才有意义），因此本次**没有任何一行**可以记 `confirmed`。凡设备依赖项按探针
> fail-closed 语义：类别零可写节点 → 该类别动作 **shipped-disabled / deferred**
> （`perf_capability_probe.dart:139-140,183,398-413`）。
> 定值映射证据：`.omo/evidence/scene-perf-reverse-gstore/task-38-feasibility.txt`。

| 优先级 | 建议 | 对应差距 | 理由 | 可行性 |
|---|---|---|---|---|
| P0 | `lib/core/perf/privileged_shell.dart`：可测试的 Shizuku 特权 shell 封装（含 `&&`/`\|\|` 哨兵、`timeout` 自限、输入校验、结构化结果） | CG-SYSFS-1、CG-CPU-1、CG-CPU-2、CG-GPU-1、CG-CPUSET-1、CG-THERMAL-1 | 一切控制动作的**传输与安全底座**；无它则任何写入都不可控、不可测 | `环境受限·待真机确认（运行时门控）` |
| P0 | Rust `perf.tunables`：只读枚举 CPU/GPU/cpuset/thermal 可调面（governor/频率/cpuset/热区/冷却设备） | CG-CPU-1、CG-CPU-2、CG-GPU-1、CG-CPUSET-1、CG-THERMAL-1 | **只读、零风险**，先建立「可调面地图」，为探针提供目标清单 | `环境受限·待真机确认（运行时门控）` |
| P1 | 能力探针（capability-probe）：逐节点验证 Shizuku-shell 可写性 | 全部 CG-* | 没有探针证据不得声称可写；探针结果为 todo 38 定值来源 | `环境受限·待真机确认（运行时门控）` |
| P1 | CPU governor 设置（读-改-校验-回滚） | CG-CPU-1 | 高频控制需求；但需 CCS/集群差异与 DAC 验证 | `unavailable-on-shell（探针门控·无设备）` |
| P1 | CPU 频率上下限设置 | CG-CPU-2 | 与 governor 同层；`min>max` 顺序与内核钳制需回读校验 | `unavailable-on-shell（探针门控·无设备）` |
| P2 | 温控阈值 / 开关 | CG-THERMAL-1 | **高风险**：误写可致过热保护失效；须最严格校验与回滚 | `unavailable-on-shell（探针门控·无设备）` |
| P2 | GPU 频率 / 功率模式 | CG-GPU-1 | 厂商节点差异大（kgsl / devfreq / mali），可写面高度碎片化 | `unavailable-on-shell（探针门控·无设备）` |
| P2 | cpuset / 进程亲和性 | CG-CPUSET-1 | 影响调度公平性，需按进程粒度谨慎 | `unavailable-on-shell（探针门控·无设备）` |
| P3 | 每应用性能档（per-app profiles） | CG-PROFILE-1 | 建立在 P1/P2 之上；**跨会话持久化 + 冲突消解**复杂 | `unavailable-on-shell（探针门控·无设备）` |
| P3 | 性能数据导出扩展（含控制前后对比） | MG4 | 依赖控制能力落地；导出本身已具备（`perf_export_service.dart:97`） | `unavailable-on-shell（依赖控制项·无设备）` |

**优先级理由概述**：
1. **先传输、后写入**：没有 `privileged_shell.dart`（P0）的哨兵 / 自限 / 校验，
   任何 sysfs 写入都可能「假成功」或阻塞单线程执行器（见 §五）。
2. **先只读枚举、后探针、再写入**：`perf.tunables`（P0）为**纯读**，可立即安全落地，
   并让探针有明确目标；这与「监控-only 现状」零冲突。
3. **风险排序**：温控（热保护）与 GPU（碎片化）风险高于 CPU governor，故降序。
4. **每应用性能档放最后**：它是在原子控制能力之上叠加持久化与多目标冲突消解的复合能力。

---

## 五、可行性 / 风险边界

### 5.1 Shizuku-as-shell 的可写性限制

- GStore 的特权路径仅经 **Shizuku shell（uid 2000）**（`gstore-perf-inventory.md:155-156`），
  传输为 `sh -c`，**stdout+stderr 合并、无退出码、阻塞 `waitFor()`**（`notepad` 继承知识）。
- 因此「命令返回了文本」**不等于**「写入成功」：权限拒绝会同样落进合并输出。
  → 必须用**哨兵**且必须链式 `&&`/`||`（**禁止** `; echo ok=1`，否则被拒写也会假报成功）：
  `... && echo GSTORE_RESULT ok=1 || echo GSTORE_RESULT err=$?`（先例
  `android/.../CaInstaller.kt:151,175,381`）。
- 插件为**单线程执行器**（`ShizukuApiPlugin.kt:22,41`）：一条挂起命令会阻塞队列中所有命令。
  → **每条特权命令必须自限**：`timeout <n> sh -c '...'`，不能依赖 Dart 侧超时释放执行器。
- **超时 ≠ 写入被中止**：原生 `waitFor()` 无法取消，超时后必须**回读节点真实状态并调和**。

### 5.2 逐节点 DAC / SELinux caveat

- sysfs 节点的**可写性逐节点不同**：即使 uid 2000（shell）对某节点有 DAC 写权限，
  SELinux 上下文（`sysfs` / 厂商域）仍可能拒绝。**不能**用「某个节点可写」外推到同类节点。
- `CaInstaller.kt:358`（CA 存储不可写）的结论**不能**泛化到所有 sysfs（`notepad` 已警示）。
- 部分节点（尤其 thermal / GPU 厂商节点）由内核或 HAL 独占，用户态写入可能被静默忽略
  （写入返回成功但读回不变）→ 必须**回读校验**，且以回读值为准。
- 结论：**每个目标节点都必须单独经能力探针验证**，这正是可行性列须由**真机**探针逐节点定值、
  而本环境一律记 `unavailable-on-shell` 的原因（详 §5.5）。

### 5.3 优雅降级（graceful degradation）要求

- **必须前置**：节点不可读 / 不可写 / 超时 / 校验失败 → 结构化失败 + 保持默认，**绝不崩溃**，
  **绝不**影响既有只读监控（`rust/gstore_mod_perf/README.md:5` 立场不变）。
- **fail-closed**：任何不确定（无哨兵、无回读、token 未过白名单）一律按「失败」处理，
  **不**推进控制状态；回滚到写入前记录的原值。
- **可观测**：每次控制动作记录「目标节点 / 写入值 / 回读值 / 结果」，供事后审计。

### 5.4 Binder-command 回退面（fallback surface）

- 若某节点的 `sh` 直写不可用，**唯一**允许的回退是**系统提供的 Binder/命令接口**，
  例如通过 `am` / `pm` / `cmd` 等已受权限模型约束的入口（而非提权）。
- 回退面**不得**引入 root / `su` / remount / SELinux 绕过；`CG-ROOT-1` 永久 **ABSENT（禁止）**。
- 回退路径同样必须走 §5.1 的哨兵 + 自限 + 校验，并保留 §5.3 的降级语义。
- 回退面是否可用同样是**探针项**；本环境无 Shizuku 设备，故同样记 `unavailable-on-shell`（详 §5.5）。

### 5.5 本构建环境的可行性定值（环境受限 · 无 Shizuku 设备）

- **环境事实**：本构建环境**没有**任何具备 Shizuku 的设备，故 `perf_capability_probe.dart`
  的运行时探针在此环境**无法**对任何候选节点给出正向可写判定（`test -w` 仅在真机 uid 2000
  shell 下才可能返回哨兵 `ok=1`）。因此本报告**没有任何一行**可以记 `confirmed`。
- **定值规则**（与探针 fail-closed 语义一致）：
  - **设备依赖的控制项**（CPU governor / 频率、GPU、cpuset、thermal、per-app profiles、
    导出扩展）→ `unavailable-on-shell`（运行时探针门控；本环境无设备，未获正向证据）。
  - **基础设施项**（`privileged_shell.dart` 传输层、`perf.tunables` 只读枚举、能力探针本身）
    → `环境受限·待真机确认`（实现已交付并单测，运行时门控待真机验证）。
- **fail-closed / shipped-disabled**：探针把「零可写节点」的类别判为不可用
  （`perf_capability_probe.dart:139-140,183,398-413`）；据此，未获真机正向证据的类别动作
  **shipped-disabled / deferred**，绝不因「路径存在」而假定可写。
- **证据**：探针行为见 `.omo/evidence/scene-perf-reverse-gstore/task-15-happy.txt`
  （混合 fixture：cpu/gpu/thermal/binder-levers 至少一个可写 → AVAILABLE；cpuset 零可写 →
  DISABLED）与 `task-15-failure.txt`（全零 → 五类全 DISABLED）；最终定值映射见
  `.omo/evidence/scene-perf-reverse-gstore/task-38-feasibility.txt`。

---

## 六、Must NOT have（重申）

以下为**不可触碰**的硬边界：

1. **不允许 root / `su` / remount / SELinux 绕过**（`gstore-perf-inventory.md:181`，C8）；
   第三方路径**仅** Shizuku shell（uid 2000）。
2. **不允许克隆 Scene**：不复制其包名、资产、字符串或任何逐字代码 / 文案；
   不引入 Scene 的伪造 CPU% 算法（`dex-evidence.md:30-31`）。
3. **不允许无证据声称**：Scene 特性必须有证据 + 置信度；控制类可行性未经**真机**探针
   （`lib/core/perf/perf_capability_probe.dart`）正向证据，一律**禁止**写成 `confirmed`；
   本环境无 Shizuku 设备，故记 `unavailable-on-shell`（详 §5.5）。
4. **不允许破坏只读立场**：既有监控能力（21 个只读 Rust 方法）必须保持只读、无副作用。
5. **不允许越过 `timeout` 自限 / 无校验直接 `sh -c`**（§5.1、§5.2）。

---

## 七、证据与 QA 指引

- 矩阵行数断言与 8 轴标题断言见
  `.omo/evidence/scene-perf-reverse-gstore/task-8-report.txt`（happy QA）。
- 失败 QA：任何 Scene 列非空却缺证据的行，已**降级为 `无核验（降级）`**
  （PSI / 存储 / 网络 / 进程 / 崩溃-ANR / 阈值告警 / 应用启动耗时），
  并在 `task-8-report.txt` 中记录原因；**未删除**，以保证矩阵完整性的同时不虚构结论。
- 交叉引用（按路径）：
  - `.omo/evidence/scene-perf-reverse-gstore/scene-feature-catalog.md`（Scene 8 轴目录）
  - `.omo/evidence/scene-perf-reverse-gstore/gstore-perf-inventory.md`（GStore 能力基线）
  - `.omo/evidence/scene-perf-reverse-gstore/dex-evidence.md`（DEX 词汇证据）
  - `.omo/evidence/scene-perf-reverse-gstore/manifest-summary.md`（Manifest 清单）
  - `.omo/evidence/scene-perf-reverse-gstore/apkid.txt`（打包器结论）
  - `.omo/evidence/scene-perf-reverse-gstore/native-libs.txt`（原生库结论）

---

## 八、后续步骤

1. **todo 38（能力探针 → 报告定值）**：以本报告 §四 建议表为输入，逐节点产出可写性证据。
   本环境无 Shizuku 设备，故已把每条可行性定值为 `unavailable-on-shell`（设备依赖项）
   或 `环境受限·待真机确认`（基础设施项）；真机到位后按探针正向证据把相应项重定值为 `confirmed`。
2. **todo 9（一致性自检）**：核对每条建议 → 差距行 → todo id 的映射，剔除孤儿建议；
   确认 Must-NOT #2（无 Scene 逐字拷贝）。
