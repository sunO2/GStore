# F-Droid 架构调研与能力补齐记录

> 记录时间：2026-09-13
> 涉及：`rust/gstore_mod_repo`（`fdroid_url.rs` / `repo.rs` / `models.rs`）、`lib/core/fdroid/*`

## 一、调研结论：F-Droid 的架构分五层

| 层 | 关键机制 |
|---|---|
| **身份与信任** | 仓库身份 = 签名密钥；信任锚点 `entry.jar`（JAR 签名）+ `entry.json.asc`（GPG）；`signer-index.json` 是「某 APK 是否由官方签名」的事实源；摘要已升 SHA-256 |
| **索引与分发** | v1：`index-v1.jar` + `index-v1.json`；v2：`entry.json` + **RFC 7396 JSON Merge Patch diff**（实测 diff 80KB vs 全量 8MB ≈ 1%）；流式入库；镜像（含图片）；IPFS；archive 独立索引 |
| **元数据模型** | 应用级（LocalizedText 多语言/截图/featureGraphic/antifeatures/releaseChannels）+ **版本级**（signer、nativecode(ABI)、usesSdk/targetSdk、逐版本权限增减、`CurrentVersionCode` beta 语义） |
| **运维与生态** | 每应用轻量 API `api/v1/packages/<id>`；搜索 API；构建状态 JSON；镜像监控 + **第三方仓库监控**；可复现构建验证；二进制透明日志 |
| **客户端** | 多源管理（优先级/禁用）；**`/fdroid/repo` 自动发现**；仓库 URL intent filter（`fdroidrepos://`）；兼容性/抗特性过滤；附近交换 |

**关于「第三方源 / 独立应用私有源（Bitwarden 式）」**：它就是**普通 repo 托管在自己域名下**
（`https://releases.bitwarden.com/fdroid/repo`）。F-Droid 侧真正的机制只有三条：
①`/fdroid/repo` 自动发现；②仓库指纹确认（深链 `?fingerprint=`）；③多源并存 + 优先级。
**不是新架构**，是补齐这三件事。

## 二、本轮完成（P0 + P1 的镜像/元信息）

### P0-3 自动发现 + 深链（`fdroid_url.rs::normalize_repo_urls`）
- 只给主机名 → 依次尝试 `<base>/fdroid/repo`、`<base>`（官方约定）
- 已给子路径 → 尊重用户意图，不猜测
- `fdroidrepos://` → https、`fdroidrepo://` → http
- 去掉 `?fingerprint=`/fragment（不参与下载）
- 下载流程改为**按候选地址依次尝试**，全部失败才报错，并回报 `resolved_url`

### P0-1 索引完整性校验（可用部分）
- 新增 `entry.json` 拉取与解析（`parse_entry`：index/diffs 的 name/sha256/size）
- 下载索引后**校验 SHA-256 与 entry.json 一致**，不一致直接失败
- `DownloadResult` 新增 `verified` / `resolved_url` / `mirror_count` / `repo_name`
- **注意**：这是**传输完整性**。`entry.json` 自身的信任仍需 JAR/GPG 验签（见「未完成」）

### P0-2 深链与指纹（Dart）
- `FdroidRepoDeepLink.parse`：解析 `fdroidrepos://` + `?fingerprint=`，指纹统一大写去冒号
- `FdroidSource` 新增 `fingerprint` 字段（可空，JSON 往返）

### P1-6 / P2-9 镜像与仓库元信息
- 解析索引 `repo.{name,description,icon,timestamp}` 与 `mirrors[].url`
- 写入 `repo_meta` 表；新增模块方法 `get_repo_meta`，Dart 侧 `getRepoMeta()` 可取
- 用途：**按索引自动回填仓库名称**、展示声明的镜像数、展示是否通过校验

## 三、未完成（按优先级，含成本）

| 项 | 说明 | 成本/风险 |
|---|---|---|
| **完整索引验签** | `entry.jar`（PKCS#7/JAR 签名）或 `entry.json.asc`（GPG）。需要引入密码学库（`x509-parser`/`rsa` 或 OpenPGP 实现），预计 **+300~500KB/ABI** | 中高：需先定验签方案与体积预算 |
| **增量更新** | 已解析 `diffs`，但还需：维护「上次索引版本」基线快照 + 实现 RFC 7396 Merge Patch | 中：存储换带宽 |
| **流式解析入库** | 当前仍全量载入内存 | 中：需改造解析路径 |
| **版本级元数据 + 兼容性过滤** | signer / suggestedVersionCode(`CurrentVersionCode` beta 语义) / nativecode(ABI) / usesSdk·targetSdk / 逐版本权限增减 / antifeatures / releaseChannels；按设备 SDK+ABI 过滤 | 中：`apps` 表结构变更 + Dart 模型 |
| **截图 / featureGraphic / 多语言文本** | 索引已带（LocalizedText/LocalizedFile），展示层缺 | 低-中 |
| **每应用轻量 API** | `api/v1/packages/<id>` 查更新，不必重下索引 | 低 |
| **可复现构建 / 透明日志** | `verification.f-droid.org`、transparency log | 低（只读 JSON） |
| **仓库健康度** | 超时/失败退避、连续失败自动禁用、镜像回退 | 低-中 |

## 四、关键发现（踩坑）

1. **Flutter release 会 tree-shake 未被调用的 Dart 代码**：本轮新增的
   `FdroidRepoDeepLink` / `getRepoMeta` 因**尚未被 UI 调用**，在 `libapp.so` 里查不到 ——
   不是没生效，而是被裁剪。**接入 UI 前，这些能力在包内是不可达的**（Rust 侧能力已随模块进包）。
2. **`mirrors` 在索引里是顶层数组**（元素含 `url`/`countryCode`），不是 `repo` 的子字段；
   我们此前只在本地配置里手填镜像，从未读取索引声明。
3. **相对路径拼接要统一去尾斜杠**，否则会出现 `//fdroid/repo`（镜像与自动发现两处都踩过）。
4. **Rust 属性宏会被"插入位置"影响**：给 `RepoManager` 写 `#[derive(Clone)]` 时若在其上方插入结构体，
   会把该 derive 抢走，导致 `conflicting implementations of trait Clone`。插入必须避开属性与定义之间。

## 五、验证

- `gstore_mod_repo`：**15 项**通过（新增 12：URL 归一化/自动发现/深链/指纹 query/sha256 校验/entry 解析，
  以及 repo 头部与镜像解析、`repo_meta` 落库往返）
- Dart：`test/fdroid_repo_deeplink_test.dart` **6 项**通过
- 全量 `flutter test`：**1568 全过**
- APK 内确认：repo `.so` 含 `entry.json`/`get_repo_meta`/`repo_meta`/`mirrors`；Dart 侧 `fingerprint` 已进包

**APK**：`build/app/outputs/flutter-apk/app-{arm64-v8a,armeabi-v7a,x86_64}-release.apk`

---

## 六、UI 接入（本轮）

把上一轮的能力接到界面，形成可用闭环：

| 位置 | 内容 |
|---|---|
| **添加源对话框**（`lib/page/fdroid_repo/add_source_dialog.dart`） | ① 粘贴 `fdroidrepos://…?fingerprint=…` **自动归一化地址**（scheme 翻译 + 去 query）② 弹出**指纹确认区**（每 2 位加冒号，便于与发布方公布值逐段核对）③ 按域名**自动填源名称**④ 提交时把指纹随源保存 |
| **源列表行**（`view.dart`） | 副标题展示 `地址 · 镜像 N · 指纹已固定 XXXX…XXXX`（短值提示身份，完整值在对话框核对） |
| **当前源头部** | 展示模块 `get_repo_meta` 回填的**索引声明名称 / 镜像数 / SHA-256 是否通过校验**；加载仓库成功后自动刷新 |

指纹失效规则：换到**不同主机**时自动清除原指纹（避免张冠李戴）；深链未带指纹则不影响。

### 本轮踩坑

1. **Riverpod `Notifier` 没有 `notifyListeners`**：状态必须走 `state = state.copyWith(...)`；
   新字段要同时改 `state.dart`（字段 + 构造默认值 + copyWith）。
2. **控制器监听器递归**：把归一化后的地址写回 `TextEditingController` 会**再次触发监听器**，
   第二次解析看到的是已去掉 query 的地址 → 指纹被清成 null。必须加 `_selfEditing` 守卫。
3. **字符串手术要避开类边界**：一次 `index` 定位跨了类，把 state 类写重复，最后整文件重写才干净。
4. **设计令牌名要对**：`AppSpacing.sm/md/xs`（不是 `boxSM`）、`AppTypography.code` 是常量而非函数、
   `AppRadius.allMD` 是 `BorderRadius` 常量。

### 验证

- `test/add_source_dialog_test.dart` **5 项**通过（域名推导、指纹分组、深链归一化+指纹区+自动填名、
  普通地址不显示指纹区、提交返回归一化地址与指纹）
- `test/fdroid_repo_deeplink_test.dart` **6 项**通过
- 全量 `flutter test`：**1573 全过**
- **APK 内确认**：`AddSourceDialog`/`FdroidRepoDeepLink`/`getRepoMeta`/`defaultSourceName`/`formatFingerprint`
  **全部进包**（对比上一轮：未被 UI 调用时这些符号会被 tree-shake 掉）

---

## 七、镜像回退 + 坏源计数（本轮）

在剩余项里挑**成本最低、收益直接**的一项先做（其余都需要密码学库 / 基线快照 / 表结构变更）。

### 关键事实（已核实，避免了一次错误实现）

`config/mirrors.yml` 里的 `url` 指向 **`.../fdroid` 目录**（如 `https://ftp.fau.de/fdroid`），
而索引在 `.../fdroid/repo/` 下 —— **必须先补 `/repo`**，不能把镜像 URL 直接当仓库根用。

### 实现

- `mirror_candidates(mirror)`：生成 `[{mirror}/repo] + normalize_repo_urls(mirror)`，去重保序；
  兼容"自建镜像直接就是仓库根"的情况
- 下载候选列表 = 用户地址（含 `/fdroid/repo` 自动发现）+ **上次成功缓存的镜像**；
  主站不可用时自动回退到镜像（当前生效地址记在 `resolved_url`，界面会显示）
- 失败记账：`fail_count`（连续失败次数，成功后清零）+ `last_error`（最近一次错误摘要，截断 200 字符）
- `get_repo_meta` 暴露两者；界面在仓库头部显示「连续失败 N 次」

### 验证

- `gstore_mod_repo` **18 项**通过（新增 3：镜像候选补 `/repo`、失败计数递增/清零、镜像缓存往返）
- 全量 `flutter test`：**1573 全过**
- APK 内确认：repo `.so` 含 `fail_count`；`libapp.so` 含 `refreshRepoMeta`
- **APK**：`build/app/outputs/flutter-apk/app-{arm64-v8a,armeabi-v7a,x86_64}-release.apk`

### 真机可验证

1. 首次加载成功后，断掉主站（或改 hosts）再刷新 → 日志出现「候选地址 N 个（含缓存镜像 M 个）」并自动走镜像
2. 连续失败后，仓库头部出现「连续失败 N 次」；成功一次后计数归零

---

## 八、修正：源与镜像的层级关系（本轮）

### 问题（用户指出，核实成立）

原实现**没有"源"这个维度**，四个证据：

| 证据 | 后果 |
|---|---|
| `apps` 表主键只有 `package_name` | 换源即**覆盖**上一个源的数据；跨仓库同名包互相覆盖 |
| `repo_meta` 主键只有 `k` | 镜像列表 / `fail_count` / `verified` / `resolved_url` **全源共享** → 第七节的镜像回退会把 A 源镜像用在 B 源（缺陷由本轮引入） |
| Dart 固定单库 `fdroid_rust.db` + 单静态实例 | 所有源共用一个数据槽 |
| `selectSource` 只换传入的 `repoUrl` | 库与实例都没变，覆盖与串源必然发生 |

另外镜像存在**两处真相**：`FdroidSource.mirrors`（从未被写入）与索引声明的 `repo_meta.mirrors`。

### 正确分层

```
源（仓库身份）= repoUrl + 指纹 + 本地配置
   ├─ 镜像（从属）：本地可增删；索引声明的镜像应回填到此，以源记录为单一真相
   └─ 索引数据（apps / statistics / repo_meta）按源隔离
```

### 本轮落地（最小修）

- **源身份键** `sourceIdentity()`：**优先指纹**（仓库身份就是签名密钥），否则用归一化地址（去尾斜杠、scheme/host 小写）。
  → 换域名/换镜像**不换数据槽**；改地址或换指纹才落新槽
- **每源一库** `dbPathForIdentity()`：`fdroid_<sha1(身份)[0:16]>.db` → `apps`/`repo_meta` 天然隔离，**镜像回退不再串源**
- **实例按源缓存** `Map<key, RustModuleInstance>`：切回旧源无需重建
- **换源通知**：`FdroidRepoManager` 在 5 处选中源变化点调用 `setActiveSource()`

### 迁移影响

旧的 `fdroid_rust.db` 作废（首次需重下一次索引，属缓存性质）。**未主动删除**旧文件，避免误删用户数据。

### 待办（完整修）

1. 模块持久化层加 `repo_id` 维度（`apps` 主键 `(repo_id, package_name)`、`repo_meta` 主键 `(repo_id, k)`）→ 单库多源、可跨源搜索
2. 索引声明的镜像**回填**到 `FdroidSource.mirrors`，界面按"源的镜像"展示与增删

### 验证

- `test/fdroid_source_identity_test.dart` **4 项**通过（指纹优先且忽略冒号/大小写、无指纹回退归一化地址、路径大小写不折叠、不同源不同库且同源稳定同名）
- 全量 `flutter test`：**1577 全过**
- **APK**：`build/app/outputs/flutter-apk/app-{arm64-v8a,armeabi-v7a,x86_64}-release.apk`

---

## 九、源 → 镜像的配置能力（本轮）

### 核对结论（用户提问）

| 问题 | 原状 |
|---|---|
| 支持多源？ | ✅ 已有（列表 + 切换 + 新增） |
| 一个源配置镜像？ | ❌ **无入口**：模型是 `List<String> mirrors`，但全库只有一处**只读**引用（显示"镜像 N"），**从未被写入** |
| 是否启用镜像？ | ❌ 无此概念 |
| 下载是否用配置的镜像？ | ❌ 不用：只传 `repoUrl`，模块用的是自己缓存的索引声明镜像 → **用户配的镜像完全不生效** |

另发现自相矛盾：默认引导把**清华镜像注册成独立源**（`tunaMirror`），而 `official` 的 mirrors 里又列了同一地址 —— 正是"把镜像当源"。

### 达成：源（身份）→ 镜像（从属）

- **模型**：`FdroidMirror{url, enabled, fromIndex}`；`FdroidSource.mirrors: List<FdroidMirror>` + **`useMirrors`**（源级回退开关）；JSON 兼容旧的字符串数组（构造器亦兼容）
- **下载生效**：payload 由裸 URL 改为规格 JSON `{url, mirrors[], mirror_first}`（模块 `DownloadSpec::parse` 兼容两种格式）；
  `mirror_first=true` → **优先试镜像**（国内网络避免先卡在官方站），`useMirrors=false` → 不传镜像
- **页面**：源行右侧「更多」→ **配置镜像**（逐条启用/禁用、删除、手动添加、**从索引导入**）+ **删除源**；服务层新增 `updateSource` 持久化
- **默认源修正**：默认只建 `official` 一个源，国内镜像作为它的**从属镜像**默认启用；`tunaMirror` 标记 `@Deprecated`（不再注册成源）

### 镜像候选顺序（Rust）

```
mirror_first=true  → [已启用镜像…] + [源地址(含 /fdroid/repo 自动发现)] + [索引声明缓存镜像]
mirror_first=false → [源地址…] + [已启用镜像…] + [索引声明缓存镜像]
```

### 验证

- `gstore_mod_repo` **19 项**通过（新增 1：DownloadSpec 兼容裸 URL/JSON/坏 JSON）
- `fdroid_repo_models_test` **17 项**通过（新增镜像断言：旧字符串格式兼容、默认启用、`useMirrors` 往返）
- 全量 `flutter test`：**1577 全过**
- **APK 内确认**：repo `.so` 含 `mirror_first`/`DownloadSpec`；`libapp.so` 含 `MirrorConfigDialog`/`configureMirrors`/`useMirrors`
- **APK**：`build/app/outputs/flutter-apk/app-{arm64-v8a,armeabi-v7a,x86_64}-release.apk`

---

## 十、多源并存 + 去重（本轮）

### 关键判断：多源**不需要**动表结构

上一轮已让**每个源独占一个库** → "源"这个维度**已经是库文件本身**。
因此多源 = 逐源各自下载 + 查询时在 Dart 侧聚合去重，**无需 `repo_id` 迁移**（比原计划的"单库多源"更省、风险更低）。

### 去重的依据（回答"不同镜像指向同一源怎么避免重复"）

**仓库身份 = 签名密钥指纹**——这正是 F-Droid 的设计（`fdroidrepos://…?fingerprint=` 就是它的传播形式）。

| 情形 | 判据 |
|---|---|
| 有指纹 | **指纹相同 = 同一个源**（URL/镜像/域名怎么变都还是它） |
| 无指纹 | 退化为归一化地址比较（去尾斜杠、scheme/host 小写） |
| 新地址命中已有源的**镜像条目** | 弹窗提示"这是「X」的镜像"，确认后**挂到该源的镜像列表**，而不是新增一个"镜像源" |

> 要做到"下载后自动判定同源"，需要从 `entry.jar` / `.asc` 提取真实指纹（需密码学库，仍为待办）。

### 多源实现

- **服务层**：`enabledSources` / `setSourceEnabled` / `loadAllEnabled()`（逐源下载，**单个失败不影响其它源**，进度按源数分摊）/ `searchAppsAcross()`（合并各源结果，**按包名去重、优先级高者胜**，带 `sourceId` 便于路由回详情库）/ `getStatistics()`（各源应用数之和）
- **Rust 管理器**：`instanceForSource()` / `downloadRepositoryTaskFor()` / `searchAppsIn()` / `appCountIn()` —— 每个源走自己的库与镜像配置
- **UI**：源列表的**单选圆点改为复选框**（启用/禁用，可同时启用多个）；主按钮改为「加载已启用源」

### 验证

- 全量 `flutter test`：**1577 全过**
- **APK 内确认**：`libapp.so` 含 `loadAllEnabled` / `searchAppsAcross` / `setSourceEnabled` / `downloadRepositoryTaskFor` / `instanceForSource`
- **APK**：`build/app/outputs/flutter-apk/app-{arm64-v8a,armeabi-v7a,x86_64}-release.apk`

### 仍未做

1. 源**编辑**（改名/改地址；目前只能删除后重加）
2. 应用详情页按 `sourceId` 精确路由（搜索结果已带 `sourceId`，详情页尚未消费）
3. 从签名提取真实指纹 → 下载后自动判定同源

---

## 十一、"第一版"与多源的收尾（本轮）

### 1) 应用详情按 `sourceId` 精确路由

原 `openAppDetail` 是**只弹 toast 的桩**（"应用详情功能开发中"）。现在：

- `FdroidApp` 新增 `@ignore sourceId`；聚合搜索写入该字段
- 详情改为**真实底部弹层**（`AppDialogs.showBottomSheet`），首行即「**来源源**：名称 · 地址」——
  多源下必须先知道数据来自哪个库，后续查询/安装才能路由回去
- 其余行：包名 / 摘要 / 许可证 / 作者 / 源码 / 网站 / 分类

### 2) 源编辑

- `AddSourceDialog` 支持 `initial`（编辑模式，带入 name/url/fingerprint）
- 源行「更多」菜单新增「**编辑源**」；`logic.editSource()` → `service.updateSource()`
- **身份变化有明确提示**：地址或指纹变了 → "仓库身份已变化，下次加载将写入新的数据槽"
  （因为数据槽是按仓库身份分库的，换身份 = 换库）

### 3) 从签名提取真实指纹 → 同源判定

关键取舍：**提取指纹只需要解出证书 DER 再 SHA-256，不需要密码学校验**，所以**不引入任何密码学库**，
只写了一个最小 DER walker（`fingerprint.rs`）：

- `certificate_der()`：走 `ContentInfo → [0] SignedData → [0] certificates → 首个 Certificate`，取完整 TLV
- `fingerprint_of()`：证书 DER 的 SHA-256，大写冒号分隔（与 F-Droid 展示一致）
- `fingerprint_from_jar()`：从 `META-INF/*.RSA|.DSA|.EC` 提取（v2 取 `entry.jar`，v1 复用 `index-v1.jar` 同一份字节）

Dart 侧 `_syncSignerFingerprint()`：

1. 源未记录指纹 → **自动回填**（身份从此由密钥决定，换域名/换镜像都不影响）
2. 与其它源指纹相同 → 记录「**同源重复**」告警（应只保留一个源，其余作镜像）
3. 与已记指纹不同 → 告警（仓库可能更换了签名密钥）

顺带修掉一个真 bug：`get_repo_meta` 把所有 kv 值都按 JSON 解析、失败fallback 成 `[]`，
导致 `name`/`description`/`fingerprint` **永远读成 `[]`**（仓库名自动回填其实一直是坏的）。

### 验证

- `gstore_mod_repo`：**24 项**通过（新增 5：证书 DER 提取 / 指纹格式 / 非 PKCS#7 拒绝 / 合成 JAR 提取 / 无签名 JAR 返回空）
- 全量 `flutter test`：**1576 通过 / 1 失败**（见下方说明）
- **APK 内确认**：Dart 含 `openAppDetail`/`sourceId`/`editSource`/`signer_fingerprint`/`_syncSignerFingerprint`；repo `.so` 含 `signer_fingerprint`/`META-INF/`
- **APK**：`build/app/outputs/flutter-apk/app-{arm64-v8a,armeabi-v7a,x86_64}-release.apk`

### ⚠️ 关于那 1 个失败（不是本轮改动引入）

`test/download_manager_view_test.dart` → "删除确认：点删除图标弹出确认框，确认后调用 deleteDownload" 失败。

证据表明它来自**工作区里既有的（未提交）弹框重构**，与本轮 fdroid 改动无关：

- `lib/core/design/app_sheet.dart` 是**未跟踪的新文件**（`??`），本轮从未创建/修改过 design 目录任何文件
- `app_dialogs.dart` 的 diff 全是"确认框改为 `AppSheetScaffold` 底部弹层 + 禁止 showDialog"的设计规范重构
- 失败的正是下载管理页的**确认框**路径：重构后 `showConfirmDialog` 在该测试宿主下没有走确认分支 → `deleteDownload` 未被调用

建议由该重构的作者确认；如需我接手修，请说一声。

---

## 十二、P1 步 1：版本级元数据 + 兼容性标记

### 省掉的两处工程（原先以为必须做）

1. **不需要改 Rust**：`search_apps` 的 SELECT 里**早已包含 `metadata, versions`** 并赋给 `AppInfo`
   （`models.rs:19-21`），FRB 生成的 Dart `AppInfo` 也**已经带这两个字段**（`generated/models.dart:23-27`）——
   数据一直在返回，只是 Dart 侧的聚合搜索把它丢掉了。
2. **不需要表结构变更**：`apps.versions` 本就是 TEXT(JSON)，扩展它无需迁移
   （这也是先做这一项而不是"加列"的原因）。

### 落地

- `FdroidAppVersion`（类型化）：versionCode/Name、apkName/size/**sha256**、minSdk/targetSdk、
  **nativecode(ABI)**、antiFeatures、releaseChannels、whatsNew
- **宽松解析**：`versions` 接受 map(key=versionCode) 或数组；缺字段用默认值兜底；
  LocalizedText（中文优先）；antiFeatures 接受 map 或数组；非法 JSON 返回空列表而不是抛错
- `FdroidApp.versions` + `suggestedVersionCode`（@ignore，来自应用级 metadata，用于 beta 语义）
- 聚合搜索透传 `metadata`/`versions`
- **详情弹层（沿用既有架构，不新开页面）新增「版本（N）」区段**：每条显示
  版本名/号、大小、ABI 集合、minSdk、发布通道、抗特性数量；
  **ABI 不兼容的用 `block` 图标标出**；与 `suggestedVersionCode` 相同的打「建议」标签

### 为什么解析写成"宽松"

沙箱内**无法访问外网**（urllib DNS 失败、web_fetch 对该源返回 525），因此拿不到真实 index 做字段核对。
于是采取：**宽松解析 + 未知形态降级为默认值**（而不是丢弃整条），并把可接受形态**写成测试用例当活文档**
（`test/fdroid_app_version_test.dart`，9 例）。首次真机拉取后建议核对一次 typed 与 raw 是否一致。

### 验证

- `test/fdroid_app_version_test.dart` **9 项** + `fdroid_repo_models_test.dart` **17 项** 全过
- **APK 内确认**：`FdroidAppVersion` / `parseAll` / `supportsAbi` / `_versionRows` / `suggestedVersionCode` 均已进包
- **APK**：`build/app/outputs/flutter-apk/app-{arm64-v8a,armeabi-v7a,x86_64}-release.apk`

### 本步未覆盖（P1 剩余）

- **SDK 兼容性过滤**（minSdk vs 设备 API level）：目前只做了 ABI 过滤，缺"设备 API level"来源
- 分类搜索（`FdroidRepoDao` 那条 TODO）、抗特性/许可证筛选
- 截图 / featureGraphic / 多语言文本展示

---

## 十三、P1 步 2/3：SDK 兼容过滤 + 分类/抗特性筛选 + 截图与多语言

### 一个纠正：分类搜索不在 `FdroidRepoDao`

`FdroidRepoDao.dart:37` 那条 `// TODO: 实现分类搜索功能` 属于**本地 Floor 表**，但核对发现
**该 DAO 只被自己的生成代码引用，没有任何运行路径使用它**（真实路径早已切到 Rust 模块）。
所以在那里实现等于写死代码。**改在活路径上做**：对已加载结果做本地筛选（不重新请求索引）。

### 1) SDK 兼容过滤

- 来源：`device_info_plus` 的 `DeviceInfoPlugin().androidInfo` → `version.sdkInt`（已缓存）
- `FdroidAppVersion.supportsSdk(deviceSdk)`：`minSdk<=0` 或设备未知时**不误判**
- `isCompatible({deviceAbi, deviceSdk})` = ABI 且 SDK 同时满足，详情页用它标记

### 2) 分类 / 抗特性 / 兼容性筛选

- 抽 `_allResults`（底层结果集）+ `_applyFilters()`（唯写 `state.searchResults` 的地方）
- 筛选条（结果头上方）：**仅兼容本机** / **隐藏含抗特性** / **分类 chips**（分类来自结果并集）
- 全部本地计算，**不重新下载索引**

### 3) 截图 / 特色图 / 多语言

- `FdroidAppMeta`（解析自应用级 `metadata`，**不新增数据库列**）：
  抗特性 key、截图、特色图、宣传图、**本地化 name/summary**
- 统一取值函数 `fdroidLocalizedText`（zh-CN → zh → en-US → en → 首个非空），版本与元数据共用
- 详情弹层**沿用既有架构**新增「抗特性」「特色图」「截图」区段；图片用**所属源地址**拼绝对地址，
  第三方图失败静默降级（`errorBuilder`）

### 两个被测试抓出来的真实问题

1. **索引 `screenshots` 是嵌套结构**：`{locale: [路径...]}`，第一版只按 `locale→字符串` 处理，
   结果截图全空——测试直接抓出来，改为递归取值（String / List / Map 三形态）。
2. **`device_info_plus` 12.x API 变了**：没有 `AndroidDeviceInfo.fromPlatform()`，
   改用 `DeviceInfoPlugin().androidInfo`（getter）。

### 验证

- `test/fdroid_app_version_test.dart` **16 项**（新增 7：元数据解析 / 嵌套截图 / 非法降级 / SDK 兼容 / 综合兼容）
- **全量 `flutter test`：1593 全过**（此前那个弹框重构引起的失败已随该重构完成而消失）
- **APK 内确认**：`FdroidAppMeta` / `setOnlyCompatible` / `setHideAntiFeature` / `setCategoryFilter` / `_extrasRows` / `isCompatible` 均进包
- **APK**：`build/app/outputs/flutter-apk/app-{arm64-v8a,armeabi-v7a,x86_64}-release.apk`

### P1 至此全部完成；P2 待办

增量更新（entry.json + JSON Merge Patch，需基线快照）· 完整索引验签（需密码学方案与体积预算）·
流式解析入库 · 每应用轻量 API · 可复现构建/透明日志 · 坏源自动退避禁用 · archive 仓（历史版本）

---

## 十四、P2 步 1：增量更新（entry.json + RFC 7396 diff）

官方实测：全量索引 8MB（压缩）/33MB（未压缩），而最新 diff 仅 **80KB** —— 约 **1%**。这是 P2 里收益最大的一项。

### 实现

| 环节 | 做法 |
|---|---|
| **基线** | 索引 JSON **gzip 存盘**在库文件旁边（`<db>.index.json.gz`），版本号记在 `repo_meta.index_version` |
| **补丁** | 自实现 RFC 7396 JSON Merge Patch（`src/merge_patch.rs`），**用规范自带的用例做测试** |
| **差异链** | F-Droid 的 diff 是**逐版本增量**（`diff/<version>.json` 把 v-1 变成 v），所以逐级回放；`plan_diff_chain` 为**纯函数**，任一级缺失即回退全量 |
| **顺序** | 候选地址循环里**增量优先**，失败才回退全量；全量成功后**也会写基线 + 版本号**，下次才能走增量 |
| **已是最新** | `entry.version == 本地版本` → **不下载、不重写数据**，直接返回现有应用数 |
| **校验** | 每个 diff 都按 `entry.json` 给的 sha256 校验，不匹配即回退全量 |
| **保护** | 差异链最长 12 级（本地过旧就回退全量）；基线超过 32MB 不做增量（合并是内存操作） |

### 取舍（要说清楚）

- 合并是**内存操作**：省的是**带宽**，CPU 与全量一致（合并后的索引是完整视图，仍会全量解析入库）。
  "流式入库"是另一项 P2 待办，两件事叠加才能真正降内存。
- 只下 1% 的前提是**本地有较新的基线**；长期不用（差几十个版本）会因链过长回退全量——这是有意的。

### 验证

- `gstore_mod_repo` **30 项**通过（新增：RFC 7396 规范 4 组用例 + 嵌套 packages 合并 + null 删除 + 非对象替换 + 差异链规划 5 种情形）
- 全量 `flutter test` **1593 全过**
- **APK 内确认**：repo `.so` 含 `entry.json`（增量入口 URL）与 `.index.json.gz`（基线缓存路径，**增量功能独有**）；`incremental` 字段名在 Dart 与 `.so` 两侧均存在
- **APK**：`build/app/outputs/flutter-apk/app-{arm64-v8a,armeabi-v7a,x86_64}-release.apk`

### 真机验证

1. 首次加载 → 日志「全量下载」，随后库旁出现 `<db>.index.json.gz`
2. 等上游发布新版本后再加载 → 日志应出现「**增量更新（entry.json + diff）**」与「增量更新成功：N → M（K 级 diff）」
3. 差值很小（KB 级）→ 说明只下了 diff

## 十五、流式下载 + 真实字节进度（P2）

### 改了什么

| 环节 | 之前 | 现在 |
|---|---|---|
| 索引下载 | `resp.bytes()` 一次性读全量 | **分块读取**（`resp.chunk()`），边下边算 SHA-256 |
| 完整性校验 | 下载完再 `verify_sha256(&bytes)` **二次扫描** | 与下载**同一次遍历**完成（`streamed_sha`） |
| 基线落盘 | `Value` → 序列化回字节 → gzip | **直接把下载到的原始字节 gzip**（省掉一份全量拷贝） |
| 进度 | 只有阶段（downloading/stored） | **字节级**：`{"phase":"index","loaded":N,"total":M,"percent":P}`，**每 5% 一档**节流 |
| Dart 进度条 | 索引阶段"不动"（0.3 → 0.9 跳变） | 按**真实百分比**在 0.3→0.9 平滑推进 |

进度事件经 **Task 流**（P1 建的模型）到达 Dart，Dart 侧原本就已订阅 `task.progress`，本轮只是把 `phase:"index"` 与 `percent` 接进进度条——**没有新增管道**。

### 诚实的边界：这还不是"真·流式入库"

峰值内存仍与索引大小成正比：解析依旧是 `serde_json::from_slice` → `Value` → `Vec<AppInfo>`。
本轮消除的是「原始字节 + `Value` + 序列化回字节」中的**一份全量拷贝**（基线那条），并让校验不再二次扫描。

**真流式**（边解析边入库、不建 `Value`）需要：类型化 serde 结构（`IndexRoot { packages: ... }`）+ 逐包处理。**这是下一步**，届时可用「类型化解析与 `Value` 解析结果等价」的测试保证零行为变化。

### 又踩了一次"产物没进包"

`build_repo_all.sh` 的 jniLibs 同步补丁**没生效**（`replace` 锚点与脚本实际文本不符），于是又一次构建出的 APK 里是**旧模块**。这次改为：以 `target/<triple>/release` 为准手动同步，并把同步段**追加到脚本末尾**；同时用 **md5 三方一致性校验**（target / release-modules / jniLibs）确认。

### 验证

- `gstore_mod_repo` **30 项**通过（新增进度节流：1% 不报 / 跨 5% 报 / 档位未跨不报 / 无 content-length 不报）
- 全量 `flutter test` 通过
- **APK 内确认**：`phase":"index` · `loaded` · `index.json.gz` · flate2(miniz ×7)；Dart 侧 `percent` ×14

## 十六、逐包流式解析（P2）

### 做法（低风险的关键）

抽取逻辑原本就在 `AppInfo::from_json_value_v2(pkg, &Value)` —— **只需要单个包的 `Value`**。
于是顶层改成只投影出 `packages`，每个包保留为 **`Box<RawValue>`（原始文本切片，不深解）**，
再**逐个包**解析成小 `Value` 交给同一个函数：

- **深层字段的解析逻辑零改动** → 行为等价由构造保证
- 并有**等价性测试**兜底：同一份 fixture 分别走「逐包解析」与「整份 Value 路径」，断言两者产出的 `AppInfo` **逐字段相同**

### 内存账（诚实）

| | 之前 | 现在 |
|---|---|---|
| 原始索引字节 | 常驻（`from_slice` 需要） | **仍常驻**（当前用 `Cursor::new(&bytes)`） |
| **整份 `Value` 树** | **数百 MB（最大一份）** | **已消除** → 变成「单包 Value」（可忽略） |
| `Vec<AppInfo>` | 常驻 | 常驻 |
| 基线落盘 | `Value` → 序列化回字节 → gzip | 直接 gzip 原始字节（已消除一份） |

本轮消掉的是**最大的一份（Value 树）**。还剩两份可省，且都很小：
1. **原始字节常驻** → 去掉需「流式下载同时写 temp 文件 + gzip 基线，再从文件流式解析」
2. **`versions`/`metadata` 的再序列化** —— 虽然包已保留为 `RawValue`，但当前仍交给 `from_json_value_v2`（其内部会重新序列化）。可在后续改为直接取 `RawValue::get()` 原文

### 顺带

- 仓库头/镜像只需 `repo` / `mirrors` 两个小字段，改为**单独轻量解出**（不再为它们建整份 Value）
- `serde_json` 打开 `raw_value` feature（已有依赖，无需新下载）

### 工具链踩坑

`debug_print!` 是 `repo.rs` 里的**局部 `macro_rules!`**（文本作用域，不跨模块）→ 新模块里改为条件编译的 `eprintln!`。

### 验证

- `gstore_mod_repo` **33 项**通过（新增 3：等价性 / 头部轻量解析与坏输入 / 坏包含包跳过不影响其它包）
- 全量 `flutter test` 通过
- **APK 内确认**：`packages`（浅投影 serde 字段）· `phase":"index` · `index.json.gz` · flate2(miniz)
- **md5 三方一致**：`target` = `release-modules` = `jniLibs`

## 十七、真机纠错：图标为空 / 图片不显示 / 增量更新从未生效

用用户给的真实源（`https://mobileapp.bitwarden.com/fdroid/repo`）核对后，发现三处"看起来对、实际不生效"：

### 1) `icon` 恒为空 —— **Rust 侧**没识别 LocalizedFile
`icon` 由 Rust 的 `AppInfo::from_json_value` → `get_localized_string` 解析。旧实现只认字符串，
遇到 **LocalizedFile 对象**（`{"en-US": {"name": "/x/icon.png", "sha256": …, "size": …}}`）直接返回默认值
→ `icon` 为空 → 详情页永远没有图标地址。**只修 Dart 侧 metadata 治不好**（icon 不在 metadata 里）。
→ 改为递归识别三种形态（字符串 / LocalizedText / LocalizedFile 取 `name`），并加真机形态回归测试。

### 2) 图片地址本身是对的（已实地验证）
`https://mobileapp.bitwarden.com/fdroid/repo/com.x8bit.bitwarden/en-US/icon_….png` → **HTTP 200 + 真 PNG**。
所以问题不在拼接。（首次 526 是路径里未编码的 `=` 让抓取工具报 SSL 错。）

### 3) `entry.json` 的三处事实（都推翻了之前的假设）
- `entry.index.name` / `diffs[].name` **带前导 `/`**（`/index-v2.json`）→ 旧写法 `{base}/{name}`
  会拼出 `base//index-v2.json`；新增 `fdroid_url::join_repo` 统一处理。
- **`entry.version` 是索引格式版本（恒为 20002），不是仓库单调版本**；`diffs` 的键是
  **上一个索引的 timestamp**。因此旧的"baseline+1 … target 逐级链"**永远不可能命中**——
  **增量更新实际上从未触发过**（一直静默回退全量）。→ 改为按本地 timestamp **单级匹配**
  （`pick_diff`），基线改存 `index_timestamp`，并加对应单测。
- 教训：**功能"存在"≠"会用上"**。上一轮以"符号在包里"就宣布完成，其实一次都不会执行；
  真数据 + 真实 URL 才是判据。

### 4) 图片走源地址（不是镜像）
规则：**图片用应用所属源的 `repoUrl`**，镜像只服务索引/diff 下载。打开详情时会记一条
`图片基地址=… （源=…）icon=…`，便于真机直接核对。
