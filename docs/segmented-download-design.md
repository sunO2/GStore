# Android/移动端 HTTP 分段下载工程方案 —— Dart/Flutter 重构设计文档

> 目标读者：需要重写 `DioDownloadEngine._downloadSegmented` 的工程师。
> 结论先行：现有实现的问题不是"并发模型"而是"进度账目"——进度必须改为**磁盘字节的可复算函数**（`已落盘字节 / total`），由单一采样点低频上报，而不是从高频事件流的滞后时间线上推断。

---

## 0. 现状诊断：为什么会出现"显示 90%，分片却早已合并完"

现有链路：

```
引擎逐 chunk emit DownloadProgress(fold, total)        ← 每收到一个网络块一次，秒级数百~上千次
        │ (StreamController 无背压，引擎 emit 不阻塞)
        ▼
Manager await for 串行消费
        │ 每条事件：速度计算 + copyWith + 200ms 节流的全量 Floor UPDATE（含 segments JSON 序列化）
        ▼
DB received（UI watch 的唯一数据源）                    ← 对事件流做低通滤波，天然滞后
```

**90% 卡死的完整因果链：**

1. **进度源是"事件"而不是"磁盘事实"**。`_downloadSegment` 里 `received` 是 sink 收到的内存计数，`fold` 只是 8 个内存计数器的求和；每条事件都要经过 Manager 的串行落库管道。
2. **消费端是瓶颈且无背压机制**。`StreamController` 是单订阅、内部 FIFO 队列无限积压；引擎侧 `emit` 不阻塞，管理器 `await for` + 全量落库逐条消化，积压队列越来越长。落库又受 200ms 节流钳制 → **DB 里的 `received` 严重滞后于引擎（更滞后于磁盘）**。
3. **引擎写盘完成 ≈ 100% 的时刻，DB 才消费到 ~90% 那批事件**。8 个 `.part{i}` 全部 `close()`，`Future.wait` 完成——此时**盘上字节 = total**，但最后一次落库值还停在 90%。
4. **merge 阶段发出 0 个进度事件**。引擎转而同步把 8 个 part 串流合入 `.temp`（1GB 约 2~5 秒），期间没有任何 `DownloadProgress`；UI 只能停在最近一次落库的 90%。等 `DownloadCompleted` 到达才一下跳到完成——观察者眼中的效果就是"进度 90% 时盘上其实已经合并完了"。

**结论：** 任何对分片大小/并发阈值/落库频率的调参都只是缓解。根治只有一条路——**把"进度"定义成不依赖事件时序、随时可从磁盘复算的函数**，低频采样上报；事件流只承载状态迁移和低频进度快照。

---

## 1. 成熟方案的核心流程（IDM / aria2 / curl / 迅雷）

### 1.1 aria2（参考**动态分片 + 控制文件续传**）

- **分片决策**：`--split=N`（默认 5）决定最大并发段数；`--min-split-size`（默认 20M）保证**每段不小于 2×min-split**：
  `有效段数 = min(split, max(1, total / (2 × min_split_size)))`。
  例：默认配置下 100MB 文件只开 2 段，1GB 文件开满 5 段。
- **段管理 = 工作队列**：文件按固定 piece 长切成逻辑 piece，`SegmentMan` 只维护少量**在飞 segment**（每次 checkout 一片），一段完成立即 checkout 下一段。**线程=并发数恒定，段数可以很多，统计粒度独立于并发窗口**。
- **Range 语义**：非流水线 HTTP 下 aria2 发 **`Range: bytes=start-`（开区间）**，配合内部期望的段长度读满即完成——**不依赖服务器返回的 end 匹配**，天然容忍服务器文件略变。
- **续传 = 控制文件（`.file.aria2`）**：存 `total_length / completed_length / piece 位图 / 在飞 piece`。resume 时读位图知道**精确到 piece（16KiB 子块位）**哪些已完成，HTTP 场景信任位图与文件长度、**不做内容校验**（除非 metalink 提供校验和 → `-V` 校验，或 `--realtime-chunk-checksum`）。
- **失败策略**：每段重试 `--max-tries`（默认 5）+ `--retry-wait`；收到 **416** 判定"resume 不可行"→ 整段重下甚至整包回退；`--always-resume` + `--max-resume-failure-tries` 控制"必须续传 vs 允许重头下"。
- **进度上报**：`aria2.getFiles()` 的 `completedLength` 只算**已完成 piece**；`tellStatus().completedLength` 额外含在飞 piece 的已收字节。客户端**轮询（~1s）**，不是推流。**单文件按偏移写入 → 没有 merge 阶段**。

### 1.2 IDM（参考**动态分割 + 同文件偏移写**）

- **动态分割**：开始时 1 条连接；有新连接空闲时把**当前最大未完成段一分为二**，新连接从后半段开始拉。并发连接数恒定（默认 8，官方建议 **4~8**）。
- **写盘模型**：所有段通过 `Range` **seek 写入同一个文件的不同偏移** → **全程无 merge 阶段**、无中间 `.part`。进度 = 各段已完成字节求和 / total。
- **续传**：进程内维护每段偏移 checkpoint；HTTP 用 `Range` 直接从偏移续。
- 与 aria2 共同的本质：**分片粒度（piece/段数）和并发连接数是两个独立的旋钮**；进度聚合永远按"已落盘字节求和"。

### 1.3 curl（参考**单流语义 + 重试/超时**）

- 单连接，`-C -` 依据本地文件大小发 `Range: bytes=size-` 续传。
- `--retry --retry-all-errors --retry-delay`；**`--speed-limit` + `--speed-time`（如 10KB/s 持续 30s 判定死链）**——这是"慢速卡死段"的标准探测法。
- 能投递到 206/200/Range 语义验证（`ResponseHead` 校验，不满足即 `CANNOT_RESUME`）。

### 1.4 迅雷（P2SP，参考**片级校验**）

- 文件切成 ~1~4MB 的片，HTTP/P2P 共拉同一套片；每片可带 **MD5/校验**，片间可互相校验对账。
- 片级校验的意义：**多源混拉时不信任字节来源，只信任片校验**。单源 HTTP 场景没有校验和时，退化为"按长度 + 结构校验"（GStore 现做 APK PK 魔数即此类）。

### 1.5 结论：GStore 应采用的最优形态

| 维度 | 采用 | 原因 |
|---|---|---|
| 分片计划 | **静态切分 + 动态工作队列**（单位 8~16MB，段数 = size/unit 上取，**并发窗口独立于段数**） | 队尾扇区尾部效应：现 8 段下 1GB 每段 128MB，最慢段单独拖全局（phase 最差） |
| 写盘 | **独立 `.part{i}` 文件 + 顺序串流 merge**（保留现状） | APK 必须单一文件安装；part 模式 resume/校验最简单可靠。见 §4.4 |
| 进度 | **磁盘事实 + 低频采样**（本发布泄的根治方案） | 见 §2 |
| 续传 | 控制文件/`segments` 记录 + part 长度推导偏移 | 见 §3 |
| 重试 | 段级 3~5 次 + 指数退避 + 抖动 + 慢速探测 | 见 §4.3 |

---

## 2. 进度聚合的正确模型

### 2.1 三条铁律

1. **进度分母 = 服务器 Content-Length（probe 得到的 total）**，不是各段实际收字节之和——各段实际和只能当分子。服务器不提供 total（chunked/gzip/未知）→ 进单流模式 + 不定长进度条（现有逻辑已正确）。
2. **进度分子 = 随时可从磁盘复算的字节数**：下载阶段 `Σ part_i.length`；merge 入口起即为 `total`。采样频率 ≤ 4 次/秒。
3. **merge 阶段计入方式**：merge 不产生新下载字节（字节早已在盘上）。正确表现是——**进入 merge 前进度先发 100%**，merge 期间保持 100% + 一个 `merging/finalizing` 阶段标识（UI 显示"正在写入…"）。**永远不要**让 merge 时间落在 90%~99% 的区间里“空转”。

### 2.2 事件模型（重定义，对照现有 `DownloadEvent`）

```dart
sealed class DownloadEvent {}

/// 低频进度快照（≤4次/秒），received = 磁盘已落盘字节，与事件流时序无关
class DownloadProgress extends DownloadEvent {
  final int received;          // 磁盘真值
  final int? total;            // null = 未知（不定长）
}

/// 阶段迁移（UI 借此显示"正在合并/写入磁盘"）
class DownloadMerging extends DownloadEvent { final int total; }

class DownloadCompleted extends DownloadEvent {}
class DownloadFailed extends DownloadEvent { final String message; }
```

- **删除逐 chunk 的 `DownloadSegmentProgress`**（Manager 本就忽略它，纯浪费队列）。
- 引擎内部保留 `_SegmentProgress`（文档不称为事件）：**并发段共享的可变计数器**，每段写盘后累加真实字节 `Σ part.length`，由 `ProgressReporter` 负责聚合 + 节流 + 对外 emit。

### 2.3 磁盘真值函数（单一事实源）

```dart
/// 下载阶段：Σ .part{i}.length（尚未 merge）
/// merge 阶段：total（所有 part 已写盘）
/// 已完成：最终文件 length
int diskBytes(String savePath) {
  final f = File(savePath);
  if (f.existsSync()) return f.lengthSync();
  var total = 0;
  for (var i = 0; i < 256; i++) {
    final p = File('$savePath.part$i');
    if (!p.existsSync()) break;
    total += p.lengthSync();
  }
  return total;
}
```

（注意与现有 `DownloadManager._diskBytes` 的区别：它在 pause/resume/终态已做"取磁盘与 DB 较大值"，但**下载中的常态路径没走这个函数**——本次重构正是把它接上。）

### 2.4 三层治理（引擎 → 管理器 → 落库）

| 层 | 现行为（问题） | 改为 |
|---|---|---|
| 引擎 | 每 chunk emit 2 个事件 | 每段完成写盘后更新共享计数；**每 ≥250ms** emit 一次 `DownloadProgress(diskBytes, total)`；merge 入口 emit `DownloadMerging` + 一次 100% |
| 管理器 | `await for` 逐事件 + 200ms 节流全量落库 | 消息循环只处理**状态迁移**事件（completed/failed/paused）与低频进度快照；进度数值直接透传（已被引擎节流，天然 ≤4 次/秒落库） |
| DB | 下载中整行 UPDATE（含 segments JSON） | 下载中只写 `received/total/speedBps/etaSec` 精简字段；**segments 仅在状态变更时落** |

**保底双保险**：引擎节流失效（防御性）时，Manager 侧对 `DownloadProgress` 再做一次 500ms 采样窗合并，保证落库频率上限；所有终态（pause/cancel/failed/completed）仍执行"磁盘值取大"校正（现状已具备，保留）。

---

## 3. 断点续传恢复语义

### 3.1 resume 时如何定位每片偏移

- 计划与续传状态持久化在 `DownloadTask.segments`（`SegmentInfo{index,startByte,endByte,received}`，现模型已具备）+ 磁盘上的 `.part{i}`。
- 启动时（plan 已按 probe total 重建，见 3.3）：
  ```
  for each segment i:
    存在 .part$i 且 length < partTotal → offset_i = part_i.length，Range: bytes=offset_i-end
                  且 length == partTotal → 标记完成，跳过
                  且 length >  partTotal → 文件已收缩/损坏 → delete 重下
    不存在           → offset_i = 0, 全新
  ```
- **定位基准以磁盘 part 长度为准**，DB 的 `received` 仅作展示（防呆：差异取 max，现状已有）。磁盘是唯一可信的写入事实。

### 3.2 片完整性校验

- 每段响应流结束 → **段级长度校验**（`partLength == partTotal`），不符 → 删除该 part + 重试（现状已有）。
- merge 后总量校验（`mergedLength == total`，现状已有）。
- 内容校验：单源 HTTP 无校验和 → 信任“段长度 + 总量 + 最终结构校验”（APK 的 PK 魔数 + `length >= total`，`DownloadManager._isValidFile` 已有）；若数据源元数据提供 SHA-256，追加校验（见 §4.5）。
- aria2 语义对照：HTTP 续传**不重算已收字节的内容**（没有校验和就不值得读盘），只信任"长度+位图"。**切勿**为 APK 全量重读做内容哈希——那是多余 I/O。

### 3.3 坏片/超时片处理（重试策略）

1. **段级重试**：失败仅重试该段，指数退避 `base(500ms) × attempt`（现状已有），加**±20% 随机抖动**防雪崩；上限 3~5 次。
2. **慢速卡死探测**（curl `--speed-*` 语义移植）：段的 `connectTimeout(15s)` + `receiveTimeout(30s)`；**10s 无新字节 → 主动 cancel 本段并立即重试**（Dio 的 `CancelToken` 粒度为每段独立，勿用全局 token）。
3. **416 Range Not Satisfiable**：resume 偏移已越过服务器当前 EOF → 文件被服务器更换。策略：删该 part，若重试仍 416，落到 §3.4 全局重探。
4. **取消（暂停）语义**：pause 走全局 `CancelToken.cancel()`，各段写盘循环 `await for` 被打断（现状已 break），保留 `.part{i}`，**不清理**——供 resume 按长度续传。仅非取消的失败才整包清理 part（现状已正确，保留）。

### 3.4 全局一致性（probe 与存储状态对账）

resume 启动时重新 probe：
- **服务器 total ≠ `task.total`** → 文件已更换 → 清空全部 `.part{i}`/`.temp`，按新 total 重新规划，`received` 归零。
- total 一致但某 part `length > partTotal` → 删该 part。
- 记录服务器 `ETag`（若提供）于 task 元数据，resume 时 `If-Range: <etag>`；ETag 不匹配 → 同样清空重来。

---

## 4. merge 阶段的设计

### 4.1 merge 是否必须？—— 对 APK：**必须，且不可跳过**

- Android `PackageManager` / `app_installer` 需要**指向单一完整文件的 file:// 路径**来安装；APK 本质是 zip 容器（EOCD/中央目录在文件尾部），签名块 v2/v3/v4 基于**整个文件字节**校验——把 8 个 `.part` 交给安装器没有任何合法途径。**"直接对 .part 顺序安装"不成立**。
- 唯一能消除 merge 的是 IDM/aria2 的"单文件按偏移写"模型（每段 `Range` seek 直接写最终文件偏移）。代价：resume 只能靠控制文件位图判断已写区域，中断残留半截、无校验、容易误判完成（aria2 文档专门强调"预分配 + bitfield"的坑）。**GStore 保留独立 `.part` + merge，是移动端最稳的组合**；若未来要消灭 merge，可预分配最终文件 + 每段独立 `RandomAccessFile` 偏移写，需配套位图型控制文件，不建议一步到位。

### 4.2 顺序串流 vs 按需读取

- **顺序串流合并**（现 `sink.addStream(part.openRead())` 逐个 part 串流）：磁盘顺序读 + 顺序写，接近磁盘带宽（UFS/eMMC 上百 MB/s），1GB 仅数秒。**正确且最优**。
- 合并目标先写 `.temp` 再 `rename(savePath)`（**同目录 rename 原子**，现状已正确）；绝不要跨文件系统 rename。
- **唯一需要改的是进度**：merge 不再是"无事件空洞"，而是"进度已满 + `DownloadMerging` 阶段标识"。

### 4.3 参数建议（Android 移动网络，针对 100MB~1GB APK）

| 参数 | 建议 | 依据 |
|---|---|---|
| 分片单位 | **16 MB**（8~32MB 可调） | aria2 `min-split-size` 20M 同量级；移动单连接 1~5MB/s 下 16MB ≈ 3~16s/段，重试粒度合理 |
| 最大分片数 | `clamp(size/16MB, 2, 64)` | 让大文件有足够"负载均衡粒度"，但**并发窗口与段数解耦**（见下） |
| 并发数 | **4**（移动网络）/ **6**（Wi-Fi 上限） | IDM 官方指引 4~8；4G/5G 上 RTT×TCP 慢启动下 >4 增益趋零且耗电 |
| 最大连接/服务器 | 与并发一致，**≤8** | 防 CDN 限速（GitHub 缓存代理 429） |
| 段重试 | 3~5 次，`500ms×attempt` + ±20% 抖动 | aria2 `max-tries=5` 同源 |
| 连接/读超时 | connect 15s / receive 30s | 移动网络抖动容忍 |
| 慢速探测 | **10s 无新字节即弃段重试** | curl `--speed-limit --speed-time` 语义 |
| 进度采样 | **250~500ms 一次**（引擎 emit）+ 500ms 落库窗 | IDM/aria2 均为 ~1s 轮询量级；移动端无需更高频 |
| 速度/ETA窗口 | 滚动 3~5s，基于**磁盘采样差分** | 用事件流算速度正是"90% 卡死"的副作用源 |

### 4.4 分片模型最终形态（动态工作队列）

```dart
// 计划：文件切成 unit=16MB 的逻辑段（可 64 段），仅 N=4~6 个并发 worker
// 每段完成 → 立即 checkout 下一未完成段（aria2 SegmentMan 语义）
// 好处：消除"最慢段拖累全局"的队尾效应；段失败只赔一个 unit 的进度
```

### 4.5 校验闭环

1. 段级：`part.length == partTotal`（无 → 删/重试）。
2. 合并级：`merged.length == total`（异常 → fail + 清理）。
3. 最终级（现状已有）：APK 存在 + `length >= total` + 头 2 字节 `PK` 魔数。
4. 可选增强：下载元数据带 `sha256` 时，merge 后计算比对，失败自动整包重下（对自有数据源有价值，GitHub release 未提供则跳过）。

---

## 5. 推荐的 Dart 实现结构（对照现状重写）

### 5.1 类划分

```
DioDownloadEngine（保留唯一入口）
 ├─ _probe()                     → ProbeResult{total, supportsRange, isCompressed, etag}
 ├─ SegmentedPlanPlanner.plan()  → List<SegmentPlan>（unit=16MB 静态切分）
 ├─ SegmentDownloader（N 个并发 worker）
 │    ├─ 每段：Range 请求 → 写 .part{i} → 段长校验 → diskCount 累加真实字节
 │    └─ 失败 → 段级重试；慢速/超时 → 独立段 CancelToken
 ├─ ProgressReporter             ← 唯一 emit DownloadProgress 的地方（250ms 节流 + 磁盘真值）
 ├─ FileMerger                   → .part* → .temp → rename + 总量校验 + DownloadMerging
 └─ ResumeState                  → part 长度推导 offset + ETag/总量对账 + 坏片删除
```

### 5.2 状态机

```
probing → planning → downloading ⇄ (暂停/失败) 
                         │
                         ▼
                     merging（进度恒定 100%）
                         ▼
                     verifying → done
                     (失败) → failed → (重试回 downloading / 整包重下)
```

### 5.3 关键骨架（可对照 `_downloadSegmented` 逐行替换）

```dart
sealed class SegState {
  const SegState();
  const factory SegState.idle() = _IdleState;
  const factory SegState.downloading() = _DownloadingState; // 持有共享 diskCount
  const factory SegState.merging() = _MergingState;
  const factory SegState.done() = _DoneState;
  const factory SegState.failed(String reason) = _FailedState;
  // 每段独立：idle↔downloading↔done 在小状态机内流转
}

class ProgressReporter {
  ProgressReporter(this.total, this._emit);
  int _partBytes = 0;            // Σ 已写盘 part 字节（合并阶段前）
  DateTime _lastEmit = ...;
  void accumulate(int onDisk) { _partBytes = onDisk; maybeEmit(); }
  void maybeEmit() { /* ≥250ms 才 emit DownloadProgress(_partBytes==total? total:_partBytes, total) */ }
  void onMergeStart() { _emit(DownloadMerging(total)); _emit(DownloadProgress(total, total)); }
}
```

### 5.4 与 `DownloadManager` 的契约变更

- `DownloadProgress` 语义升级为"磁盘真值、≤4 次/秒"，Manager 的 `_lastSaveTs`(200ms) 可简化为直落（或保留 500ms 上限窗）。
- Manager 下载中**不再全量落库**：`save(received/total/speed/eta)` 走精简 UPDATE；`segments` 在 `queued ↔ downloading ↔ paused` 的状态迁移点落库（resume 需要 `SegmentInfo` 恢复计划偏移的前提是段计划缓存）。
- 速度/ETA 计算改用**磁盘采样差分**（在 `_processQueue` 或定时采样处做），废弃按事件流 `_computeSpeed`（可保留但改喂采样点）。

---

## 6. 常见坑与处理策略

| 坑 | 现象 | 处理 |
|---|---|---|
| 服务器不支持 Range | probe 返回 200（非 206） | 单流模式（现状已有）；顺带校验 `Accept-Ranges` 头双保险 |
| 服务器忽略 Range（返回 200 而非 206） | 段请求拿到全量流，part 超长 | 段请求收到 200 → **立即中止该段并整体回退单流**（aria2 `isRangeSatisfied` 校验即此语义）；切勿把整文件写进 part0 |
| Content-Length 缺失 / chunked | total 未知 | 单流不定长进度条；不切段 |
| gzip 编码 | 解压后字节 ≠ Content-Length；Range 无法定位 | probe 复用 `x-gstore-decoded-encoding` 标记（现状已有）；段内再加防御：part 首 2 字节 `0x1f 0x8b` → 中止回退单流 |
| 304 Not Modified | 条件请求下被 CDN 命中 | GStore 不发条件头（除 `If-Range` 续传场景）；若未来发，需处理 304 语义 |
| 416（resume 越界） | 服务器文件已换 | 删该段 → 重试 → 仍 416 → probe 对账 ETag/total → 不一致则清空全量重下 |
| 签名 URL 过期（GitHub asset/proxy 短时效） | 跑到一半 403/signedURL 失效 | **URL 惰性解析**：引擎接收 `String Function()? urlProvider`，段重试时重新解析（配 Git 代理场景必备） |
| CDN 连接数限速 | 并发 8+ 触发 429/限速 | 并发钳到 4~6；429 指数退避 + 尊重 `Retry-After` |
| 磁盘满 / 写入失败 | merge/写段抛 IO 异常 | 启动前校验存储剩余空间 ≥ total；写盘异常按段失败处理并给出明确错误 |
| 后台 Doze 杀进程/断网 | 长下载 1GB 中途被挂起 | Android 前台服务 + 部分 WifiLock；`DownloadTask.status` 已支持 paused 恢复语义 |
| rename 跨文件系统失败 | `.temp` 与目标不同盘 | 保证同目录（现状）；rename 异常时回退"复制+删除" |
| 进度"先满后回跳" | received 取磁盘/DB 较大值导致回退 | 归一到柱状模型：磁盘真值单调，DB 只是缓存；终态统一 `max(received, disk)` |

---

## 7. 重构验收清单（对照现有代码逐项）

- [ ] `_downloadSegmented` 改为动态工作队列（N worker + 段计划池，unit 16MB，段数上限 64）
- [ ] 引擎删除逐 chunk 双 emit，改为 `ProgressReporter` 250ms 节流 + 磁盘真值；merge 入口发 `DownloadMerging` + 100%
- [ ] `DownloadManager` 下载中落库改用磁盘采样差分（speed）与精简 UPDATE；`segments` 仅在状态迁移落库
- [ ] resume：part 长度推导偏移 / ==partTotal 跳过 / >partTotal 删除；probe total/ETag 对账清场
- [ ] 段级重试 5 次 + 抖动退避 + 10s 慢速探测 + 段独立 CancelToken；416 落到全局重探
- [ ] URL 惰性解析（proxy/签名 URL 过期场景）
- [ ] 保留既有校验：段长 / merged==total / APK PK 魔数（可加 sha256）
- [ ] 回归：`dart analyze lib/`、`flutter test`、`flutter build apk --release --target-platform android-arm64`