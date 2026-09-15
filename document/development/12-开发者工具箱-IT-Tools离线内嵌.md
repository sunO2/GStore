# 开发者工具箱（IT Tools 离线内嵌）

> 把 [it-tools](https://github.com/CorentinTh/it-tools) 的离线包内嵌进 App，
> 入口：**我的 → 工具 → 开发者工具箱**。

## 1. 定位

it-tools 是一套开发者常用小工具（Token/UUID/哈希/JSON/YAML/正则/时间戳转换…共 90 个）。
上游已停更（最后提交 2026-02-12），因此**fork 自维护**，并做了两件上游没有的事：

1. **移动端适配**（响应式断点、AppBar + 抽屉导航、`n-form-item` 左标签窄屏改堆叠、
   `n-grid` 折叠单列、`n-table` 容器内横滚、安全区 / `dvh`）
2. **离线包构建与宿主主题桥接**（`pnpm build:embed`）

fork 仓库当前在 `~/develop/tools/it-tools`（`origin` 已改名 `upstream`，便于后续同步上游）。

## 2. 方案裁决：解压到私有目录后 **`file://` 直接加载**

离线包先解压到应用私有目录，再由 WebView 以 `file://` 加载入口 `index.html`。
不走 `file:///android_asset/…`，也不起本地 HTTP 服务。

| 方案 | 判定 |
|---|---|
| `file:///android_asset/assets/it_tools/…`（直接读 APK 内资产） | ❌ 资产在 APK 内部，Android 10+ 对 file 源的子资源加载限制多，且无法独立于 APK 更新 |
| 解压到私有目录 → `InAppLocalhostServer` 托管 | 可用，但要维护服务生命周期与端口；本方案曾按此实现，后改用 `file://` |
| **解压到私有目录 → `file://` 直接加载** | ✅ 当前采用：无服务、无端口，加载路径最短 |

### file 源的两个硬前提

1. **离线包必须是相对路径 + hash 路由**——`pnpm build:embed` 已保证
   （`BASE_URL=./`、`VITE_ROUTER_MODE=hash`），否则 `file://` 下相对资源与深链都会挂。
2. **WebView 必须开 `allowUniversalAccessFromFileURLs`**——离线包入口是
   `<script type="module" crossorigin>`，module 脚本按跨源规则抓取，file 源默认被拦。
   `InAppWebViewSettings` 默认值是 `false`（`allowFileAccessFromFileURLs` 亦为 `false`，
   且当 universal 为 `true` 时它会被忽略）。

   > 这一条漏了的表现是**白屏且不报错**，排查时优先看这里。
   > 注：仓库既有的 `assets/auth/auth_des.html` 用的是传统 `<script>`，
   > 不能作为「file 源能跑 module」的先例。

代价：首次进入要解压一次（约 13MB / 278 个文件），因此放在**后台 isolate**里做，
并用版本标记避免重复解压。

路由形态：离线包构建为 **hash 路由**（`#/token-generator`），不依赖服务端 history 回退。

## 3. 资产分发与构建链路

```
it-tools fork                     GStore
pnpm build:embed
  └─ dist-embed.zip  ──复制──▶  assets/it_tools/it-tools.zip（3.9 MB）
                                  └─ pubspec.yaml assets 声明
                                        └─ rootBundle.load → 解压到 <docs>/it_tools/
```

离线包构建产物（fork 侧）：

| 参数 | 值 |
|---|---|
| `BASE_URL` | `./`（资源相对路径） |
| `VITE_ROUTER_MODE` | `hash` |
| `VITE_PWA` | `disabled`（不生成 Service Worker） |

zip 内部为**根级平铺**（`index.html`、`assets/…`），没有顶层目录前缀。

## 4. 解压策略

| 项 | 值 |
|---|---|
| 目标目录 | `getApplicationDocumentsDirectory()/it_tools` |
| 版本标记 | `<目录>/.extracted_version`，内容为解压时的应用版本号 |
| 触发条件 | 目录不存在 **或** 标记与应用版本号不一致 |
| 执行线程 | `compute()` 后台 isolate |

> ⚠️ **离线包内容变更时必须提升 `pubspec.yaml` 的版本号**，否则版本标记不变、
> 老用户不会重新解压，会继续用旧包。这是「用应用版本号做标记」换来的代价——
> 换来的是**每次打开不必读取 3.9MB 资产**。

本次同时处理的边界：
- **zip-slip 防护**：拒绝绝对路径与 `../` 越界条目（新增单测覆盖）
- **解压前清空目标目录**：升级后若删过文件，增量覆盖会留下残骸

### 手动强制重新解压：「缓存管理 → 应用资源」

「换包必须升版本号」在发布时容易漏，所以额外提供了手动入口：

- 位置：**我的 → 缓存管理 → 「应用资源」分组 → 开发者工具箱资源**
- 展示：解压后的实际占用（`directorySize`），清理按钮复用缓存页既有交互
- 清理内容：整个 `it_tools` 目录（**含版本标记**），因此下次进入该页面必然
  重新从资产解压
- 「一键清理」也会一并清掉（它遍历全部缓存项），确认弹窗文案已相应补充

实现上只是把它注册成一个普通 `_CacheSpec`（`cache_service.dart`），
从而自动获得分组展示、大小统计、单项清理，以及 Agent 的 `cacheManage` 工具支持，
不额外写一套清理逻辑。

> 解压目录在**文档目录**而非临时目录，不属于 `temp_files` 的清理范围，
> 不会被临时文件清理规则误删。

## 5. 宿主主题桥接

页面打开时把当前主题经 **URL query** 传给离线包（`file://` 同样支持 query）：

```
file:///data/user/0/<包名>/app_flutter/it_tools/index.html?hostTheme=%2318a058&hostDark=0#/
```

离线包侧（fork 的 host bridge）三条通道任选，可叠加：URL query、
`postMessage`、`window.ItTools.setTheme`。生效范围为两处并保持一致：

- it-tools 自建组件 `c-*`（primary 色板由该色推导）
- naive-ui 原生组件（经 `n-config-provider` 的 `themeOverrides.common`）

只覆盖 `primary`，`warning / success / error` 保留语义色。

### 导航桥接（内嵌模式下页内导航头由本页 AppBar 承担）

以 `hostEmbed=1` 启动时，离线包会隐藏**页内导航头**与抽屉里冗余的语言/深色/社交入口，
导航能力改由本页 AppBar 经 `window.ItTools.*` 反向驱动；页面则通过 JS handler 回传状态，
保证 AppBar 的图标与选中态跟页面一致。

| AppBar 动作 | 调用 | 说明 |
|---|---|---|
| ☰ 工具列表 | **本页原生弹层**（清单由页面推来），选中后 `window.ItTools.navigateTo(path)` | 不再使用页内抽屉 |
| 🔍 搜索 | `window.ItTools.openSearch()` | 打开命令面板 |
| 🌐 语言 | `window.ItTools.setLocale(code)` | 由 App 底部弹层选语言后下发 |
| （备用） | `window.ItTools.goHome()` / `openMenu()` / `closeMenu()` | 返回首页 / 页内抽屉（原生弹层不可用时的兜底） |
| （自动） | `window.ItTools.setTheme({ primaryColor, isDark })` | App 主题变化时重新下发，页面始终跟随 App |

页面 → App 有两条回传通道（均实测过）：

`itToolsState`（状态）：

```json
{ "path": "/token-generator", "locale": "zh", "isDark": false, "menuOpen": false }
```

`itToolsTools`（工具清单，挂载时推一次，切换语言后重新推）：

```json
[
  { "category": "Crypto",
    "tools": [{ "path": "/token-generator", "name": "Token generator", "description": "…" }] }
]
```

实测载荷为 **10 个分类 / 86 个工具**，分类名与工具名均已按当前语言本地化。

> **为什么清单要由页面推**：内嵌模式下页内抽屉被原生弹层替代，但「分类名 / 工具名」
> 的本地化只存在于页面侧（it-tools 的 locale 数据）。所以清单必须来自页面，
> App 只负责展示、过滤与选择，不重复维护一份工具元数据。
>
> 原生弹层的解析入口是 `parseItToolsToolGroups()`：各平台对 `callHandler` 参数的
> 解码不一致（多数给已解码的 `List`，个别给 JSON 字符串），两种都接受，
> 结构不符的条目跳过而不是让整页崩掉——这条有独立单测锁住。
>
> 面板打开时还会**自动把当前工具滚到可视区中间**（清单 80+ 项，不定位得手动找）：
> 给当前行挂 `GlobalKey`，首帧布局完成后调用
> `Scrollable.ensureVisible(alignment: 0.5)`，**零时长直接跳到位**——弹层本身
> 正在上滑，再叠一层滚动动画会很跳。同样有 widget 测试守着。
>
> ⚠️ 面板里的行必须包一层 `Material(color: Colors.transparent)`：
> `AppSheetScaffold` 的容器是**带底色的 `DecoratedBox`**，直接把 `ListTile` 放进去，
> 水波纹会画在自己的 Material 上而被遮住（debug 下直接断言失败、release 下表现为
> **点击没有反馈**）。这是写测试时才暴露出来的。

- `path` 变化即代表页内发生了路由跳转（原生列表据此标出当前项）
- `locale` / `isDark` 用于 AppBar 的选中态与图标
- 页面就绪前 AppBar 动作置灰，避免点了没反应
- 内嵌模式下导航到任意工具后抽屉会自动收起（否则会一直盖着页面）

## 6. 代码结构

| 文件 | 职责 |
|---|---|
| `lib/core/service/it_tools_service.dart` | 解压（含版本标记、zip-slip 防护、isolate）与清理（`clearExtracted`） |
| `lib/page/it_tools/view.dart` | 页面：解压 → `file://` 加载 WebView；AppBar 与桥接；加载态与失败重试 |
| `lib/page/it_tools/tool_list.dart` | 工具清单模型、`itToolsTools` 载荷解析、原生工具列表面板（含自动定位） |
| `lib/page/cache_manage/cache_service.dart` | 「开发者工具箱资源」缓存项注册（统计 + 清理） |
| `lib/core/routers.dart` | `AppRoute.itTools` |
| `lib/core/router/app_router.dart` | `GoRoute` 注册 |
| `lib/page/home/tab/mine/view.dart` | 「工具」卡片区入口 |
| `assets/it_tools/it-tools.zip` | 离线包资产 |
| `test/it_tools_service_test.dart` | 解压与清理单测（6 例） |
| `test/it_tools_tool_list_test.dart` | 工具清单载荷解析单测（4 例） |

## 7. 测试与验证

GStore 侧：

- `dart analyze`（新增/改动文件）→ No issues found
- `test/it_tools_service_test.dart` → 3 例通过（根级/嵌套解压、zip-slip 拒绝、同名覆盖）
- `flutter test` → **1713 例全过**
  （注：本机缺 `libsqlite3.so` 软链时 DB 测试会失败 77 例，属既有环境问题，
  用 `LD_LIBRARY_PATH=/tmp/cc-sqlite` 指向软链后全绿，详见 `app-snapshot.md` §8）
- `flutter build apk --release --target-platform android-arm64` → ✓ 78.2MB
- **APK 内资产校验**：`assets/flutter_assets/assets/it_tools/it-tools.zip`
  与 `assets/it_tools/it-tools.zip` 字节完全一致（4,121,127 bytes）

> 曾经踩的坑：本机上 `dart analyze` 一度卡 8 分钟不出结果，原因是**残留 24 个
> `flutter_tester` 僵尸进程 + 两个 1GB 级 IDE 语言服务器**把 62G 内存吃到 swap 全满。
> 清掉僵尸进程后同一条命令 **1.8 秒**完成。遇到「命令莫名卡死」先看 `free -h`。

离线包（it-tools fork）侧：

- `pnpm typecheck` / `pnpm build` / `pnpm build:embed` 均通过
- 单测 34 文件 / 144 用例全过
- 汉化：86 个工具页 × 移动视口逐页扫描，中英文均 **0 处 raw key 泄漏**（详见 fork 的 `docs/i18n.md`）

## 8. 已知限制与后续可做

- **`file://` + ES module 需真机确认**：WebView 版本/ROM 对 file 源的 module 脚本策略有差异。
  若真机出现白屏，排查顺序是——
  1. 确认 `allowUniversalAccessFromFileURLs` 确实生效（见 §2 前提 2）
  2. 开 `isInspectable: true` 看 WebView 控制台是否有 CORS / module 加载报错
  3. 仍不行则回退到 `InAppLocalhostServer` 托管（本方案的原实现，改动仅在
     `ItToolsService`/`ItToolsPage` 两个文件内，不涉及离线包本身）

  该风险无法在本机验证：本地只有 headless Chrome，没有 Android WebView。
- 首次解压无可视进度（只有不确定态 loading）；13MB 在多数机型 <1s，暂够用
- 离线包体积 3.9MB（解压后 13MB），大头是两个懒加载 chunk：
  `c-diff-editor`（Monaco，3.02MB）与 `mac-address-lookup`（OUI 数据，3.19MB）。
  其中 **Monaco 已做移动端降级**：`text-diff` 在窄屏改用「两个多行输入框 + 行级 diff」，
  Monaco 走异步组件不会下载（实测移动端 JS 总下载 1.07MB，桌面 4.08MB）。
  `json-viewer` 实际未使用 Monaco（此前文档写错，已更正）。
  如需继续瘦身，可考虑精简 `oui-data` 或按需加载。
- 离线包**暂不支持独立于 APK 热更新**；若要做，可在版本标记里加入远端版本号比对
- 内嵌页与 App 的原生交互（复制到剪贴板回传、跳转）尚未接入，目前是可用的闭环
