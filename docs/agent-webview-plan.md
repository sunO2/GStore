# Agent WebView（Phase 1）

## 目标

给 AI 助手一个可执行 JS 的页面调试工具，用于：

- 读取 JS 渲染后的正文/DOM
- 点击、输入、等待 SPA 就绪
- 抓取页面实际发出的 XHR/fetch（URL、method、headers、body、状态、响应）
- 执行自定义 JS 提取数据

静态正文仍优先 `webFetch`；单个 API 仍优先 `httpRequest`。

## 选型

使用项目已有的 `flutter_inappwebview: ^6.1.5` 的
`HeadlessInAppWebView`，不新增浏览器引擎。

- `HeadlessInAppWebView`：无可见 Widget，后台真实 WebView
- `shouldInterceptRequest`：所有资源请求元数据
- `onAjaxReadyStateChange`：XHR 状态/响应文本
- 注入 UserScript：包裹 `fetch`，补全 fetch 请求/响应体
- `evaluateJavascript` / `callAsyncJavaScript`：内容、点击、输入、eval

## 代码

```text
lib/core/webview/
├── webview_session_service.dart   # 单页 WebView 会话 + 工具分发
├── webview_request_store.dart     # 有界、脱敏的请求时间线
├── webview_scripts.dart           # fetch/nav hooks + DOM 操作脚本
├── webview_url_policy.dart        # 公网/子资源 URL 安全
└── webview_models.dart            # 记录/异常模型
```

Agent 工具：`webView`（`agent_tool_spec.dart` / `agent_service.dart`）。

## 工具 API

```text
webView(action=open, url=..., waitUntil=load|networkIdle, settleMs=700)
webView(action=content, format=text|readability|html, maxChars=8000)
webView(action=requests, filter=..., method=..., includeBodies=true, limit=20)
webView(action=eval, script='return document.title')
webView(action=click, selector=..., index=0, force=false, waitMs=500)
webView(action=type, selector=..., text=..., submit=false)
webView(action=wait, selector=... | ms=...)
webView(action=status | logs | close)
```

## 请求抓取边界

| 层 | 能拿到 | 拿不到 |
| --- | --- | --- |
| `shouldInterceptRequest` | 所有资源的 URL/method/请求头/主框架 | POST body、响应状态/头/体 |
| XHR `onAjaxReadyStateChange` | XHR 状态、响应头、responseText | 非文本 responseType 的完整内容 |
| fetch UserScript | fetch 请求/响应体、状态、耗时 | 页面外（Service Worker）发起的 fetch |
| performance（未启用） | 资源类型/耗时 | headers/body |

所以“完整请求”指 **XHR/fetch 请求+响应体**；
图片/脚本/CSS 等静态资源只有元数据，这是 Android WebView 的公开 API 边界。
需要全量 HAR 时，可后续接 CDP（仅开发）或 MITM 代理，不作为 Phase 1。

## 安全

- 主框架只允许公网 http/https；子资源允许 data/blob
- 拒绝 file/content/intent/javascript/私网/回环/云元数据
- `allowFileAccess`/`allowContentAccess` 关闭；禁止弹窗、自动开窗、混合内容
- 请求头默认脱敏（Authorization/Cookie/Set-Cookie/token 等）
- 单页、200 条请求、单条 body 64KB、页面空闲 3 分钟自动关闭
- 页面内容是不可信数据；提示 Agent 不执行页面内指令
- Release 下 Android 默认禁止明文 HTTP，工具只接受 https

## 测试

单元测试：

```text
test/webview_request_store_test.dart
test/webview_url_policy_test.dart
test/agent_webview_tool_test.dart
```

真机集成测试（本地 loopback HTTP 服务，debug 清单允许 cleartext）：

```bash
flutter test integration_test/webview_smoke_test.dart -d <deviceId>
```

覆盖：open/networkIdle → content → XHR/fetch 抓包 → eval → click → DOM 更新。

## Phase 2 已落地

- 可见 WebView 调试页（AI 设置 → WebView 调试）：人工登录/验证码，Cookie 与 headless 共用
- `scroll`：滚动到选择器或指定 x/y
- `har`：HAR 1.2 风格导出（静态资源通常没有响应体）
- click/type 已包含在 Phase 1

## 后续

- 截图（需要多模态工具结果或工作区导出）
- 请求筛选/详情独立 UI
- 多页面/多标签
- Phase 3：本地 MCP/WS 适配层、CDP 开发调试、与 MITM 代理联动

## 用户可见内置浏览器（2026-11-28）

AI 对话里的 Markdown 链接此前跳到 `WebPage`，而该页只是个空 Scaffold
（webview 代码被注释），所以是白屏。现在补成完整的浏览器页：

- **地址/搜索栏**：点标题栏弹出输入框；`resolveWebInput` 判断网址还是搜索
  （裸域名补 `https://`，IPv4 直接打开，其余走 Bing）。
- **历史记录**：`WebBrowserStore` + SharedPreferences，按 URL 去重、
  置顶、最多 200 条；过滤 `Redirecting…` 之类的重定向中间页。
- **书签**：标题栏星标一键收藏/取消；列表可单独删除。
- **更多菜单**：底部 `⋯` 弹出宫格（4 列）：输入网址 / 搜索网页 / 历史记录 /
  书签 / 收藏页面 / 刷新 / 复制链接 / 清空历史。
- **导航**：后退/前进/刷新（加载中变停止）/系统返回退出页面；
  非 http(s) 协议（mailto/tel/intent…）不打开，避免白屏。

测试：

```text
test/web_view_page_test.dart     10 项（URL 归一化、搜索判定、更多宫格、历史列表）
test/web_browser_store_test.dart  6 项（去重置顶、上限、收藏、清空、持久化）
```

### 浏览器工具箱与搜索建议（2026-11-28）

- 「更多」改为 **5 列标准网格**（只有内部分割线，无单元格底色/边框），
  左右留出 `AppSpacing.lg` 内边距；按钮改为浏览器工具，不再重复标题栏/
  底栏已有的「输入网址 / 搜索 / 刷新 / 复制 / 收藏」。
- 工具：书签、历史、页内查找、夜间模式、电脑模式、字体大小、查看源码、
  页面信息（含证书）、资源嗅探、清除数据。没有页面时依赖页面的工具禁用。
- 输入框接入必应搜索建议：`api.bing.com/qsonhs.aspx?type=cb&q=`，
  260ms 防抖、失败静默、点建议直接搜索；网址输入不请求建议。
- 夜间模式用注入样式实现（换页后自动重新注入）；电脑模式切换 UA 并重载；
  字体大小走 Android `textZoom`；页内查找用 `findAllAsync/findNext`；
  源码取当前 DOM `outerHTML`（导航中会提示稍后再试）。
- 清除数据同时清 Cookie / WebStorage / 缓存，会连同 AI 网页工具的登录态，
  因此走危险操作确认弹层。

### 浏览器设置页（2026-11-28）

「更多」里的「清除数据」改为「设置」，进入独立的浏览器设置页
（`/GStore/webViewSettings`），作为后续 WebView 能力的配置入口。

设置项（`WebViewSettings`，SharedPreferences `web_view_settings_v1`）：

| 分区 | 配置 |
|---|---|
| 搜索 | 默认搜索引擎：必应 / 百度 / Google / DuckDuckGo / 自定义（模板需含 `%s`） |
| 显示 | 夜间模式、电脑模式、字体大小（70–200%） |
| 内容 | 加载图片（无图模式）、JavaScript |
| 隐私与数据 | 缓存、第三方 Cookie、清除浏览数据（Cookie/WebStorage/缓存） |
| 其他 | 恢复默认设置 |

生效方式：

- 新页面：直接用在 `initialSettings`（JS/图片/缓存/Cookie/UA/textZoom）。
- 当前页面：设置页返回后 `setSettings` + 重新注入夜间模式；UA/JS/缓存/Cookie/
  图片开关变化时自动重载。
- 地址栏搜索用配置的模板（`resolveWebInput(..., searchTemplate:)`），
  必应建议保持不变。
- 搜索/显示等快捷开关（夜间、电脑、字体）在「更多」里操作时也会写回设置。

测试：

```text
test/web_view_settings_test.dart       7 项（默认值/模板/JSON/持久化）
test/web_view_settings_page_test.dart  4 项（分区/夜间模式/引擎/字号）
test/web_view_page_test.dart          17 项（宫格含「设置」、禁用态等）
```

### 下载 / Web 认证 / 源码视图（2026-11-28）

- **下载**：监听 `onDownloadStartRequest`，用 `resolveWebDownloadFileName`
  解析文件名（suggestedFilename → Content-Disposition → URL → MIME 补后缀），
  交给 `IDownloadService.download(..., installAfterDownload: false)`；
  成功后提示「已加入下载」，点「查看」进入下载管理器；工具宫格新增「下载」入口。
- **Web 认证**：`onReceivedHttpAuthRequest` 弹出统一账号密码弹层，返回
  `HttpAuthResponse(PROCEED)`；并发 challenge 共用同一个弹层。客户端证书请求
  （`onReceivedClientCertRequest`）自动取消并提示不支持。
- **源码视图**：改用 `AppCodeView`（re_editor 封装，只读 + 行号 + XML 高亮 +
  双指缩放），替换原来的纯文本 SelectableText。

**顺带修复 rhttp 多引擎崩溃**：下载会启动 `flutter_foreground_task` 前台服务，
它在同一进程里创建第二个 Flutter 引擎并重新注册插件；`librhttp` 的
`init_android` 再次调用 `ndk_context::initialize_android_context` 触发
`assertion failed: previous.is_none()` → SIGABRT（首次下载必崩）。
已在 fork `sunO2/rhttp` 增加引擎引用计数（首个引擎初始化、最后一个释放），
pubspec 指向 `eecda0eb860f6c6af75fb4912138f2bbb4f38678`。

测试：

```text
test/web_download_test.dart   6 项（文件名解析/Content-Disposition/MIME 补齐）
test/web_view_page_test.dart 12 项（宫格含「下载」、源码用 AppCodeView、认证弹层）
```

### WebAuthn（Passkey）与应用内浏览器工具栏（2026-11-28）

**WebAuthn / Passkey**

`navigator.credentials.create/get` 之前直接失败：`flutter_inappwebview` 没有暴露
AndroidX 的 WebAuthn 开关。已在 fork `sunO2/flutter_inappwebview_android` 中：

- `androidx.webkit` 1.12.0 → **1.14.0**（`setWebAuthenticationSupport` 从 1.14 才有）
- `InAppWebView.prepare()/setSettings()` 中，支持时调用
  `WebSettingsCompat.setWebAuthenticationSupport(settings, WEB_AUTHENTICATION_SUPPORT_FOR_APP)`

真机（webauthn.io → Register）验证：日志出现
`Fido2FullScreenActivity` / `[NativeAppRegisterOperation]`，说明 WebView 已把
WebAuthn 交给系统 Credential Manager；本次测试因设备未登录 Google 账号、
GMS accounts provider 不可用而未完成注册（环境限制，不是集成问题）。

**工具栏调整**

- 底部按钮：小扳手 → **三个点**（`TablerIcons.dots`，"更多"）
- 「更多」宫格改为 **5 列 × 2 行一页，可左右翻页**（PageView + 页码点）；
  10 个工具正好一页，以后新增工具会自动分页
- 设置不再作为宫格按钮占位，固定在弹层标题栏右侧（齿轮），
  避免最后一行只剩一个按钮

### WebAuthn 模式与 Google 白名单（2026-11-28）

WebView 的 WebAuthn 有两条路，均由 Google 侧把关：

| 模式 | 行为 | 前置条件 |
|---|---|---|
| `browser`（默认） | 可为任意网站做 WebAuthn | Google Password Manager 需把**签名证书**加入浏览器白名单 |
| `app` | 只为「与本应用关联」的网站做 WebAuthn | 网站 `/.well-known/assetlinks.json` 需包含 GStore 包名 + 证书指纹 |
| `none` | 关闭 | — |

模式通过 `AndroidManifest.xml` 的 meta-data 配置（无需改插件）：

```xml
<meta-data android:name="com.suno2.gstore.webauthn_mode" android:value="browser" />
```

实测（Pixel 4 / Android 13 / GMS 26.25）：

- `app` 模式：webauthn.io 创建通行密钥 → 系统弹层报
  `Failed to get asset links from the relying party, error code 404`
- `browser` 模式：GMS 日志
  `[FidoBrowserApiChimeraService] Rejecting browser request ... certificate (...) is not recognised`
  → `FIDO2_PRIVILEGED_API is not available`

也就是说：WebView → Credential Manager 的链路已打通（能拉起系统通行密钥界面），
但「任意网站」的通行密钥需要向 Google 申请 privileged browser 白名单
（[申请表单](https://docs.google.com/forms/d/e/1FAIpQLScRuk9tTg0QPfSWl9SbpbIorX8xx2FCXlmoUYftCX2MxG4qyg/viewform)，
提交发布签名证书指纹）。自有域名则可切到 `app` 模式并部署 assetlinks.json。

发布证书 SHA-256（当前测试包）：`00F56FCF376C4C212B5CA537C94BDB960123808566EF847CE0015ABC15F40AA4`

### Passkey 闪退排查（2026-11-28）

- Dropbox 里唯一一条 `com.suno2.gstore` 的 tombstone 是 **09:13** 的
  `assertion failed: previous.is_none()`（下载启动前台服务导致 rhttp 二次
  初始化），该问题已在 `rhttp eecda0e` 修复；之后的构建没有新的 tombstone。
- 复测（重启设备后）：`webauthn.io` → Register / Authenticate，应用进程
  保持存活，只有 GMS 拒绝：
  `Rejecting browser request ... certificate (...) is not recognised`，
  WebView 收到 `FIDO2_PRIVILEGED_API is not available`，页面显示失败提示。
- 设备重启前曾出现多次 `system_server_wtf`（GMS fonts/chimera provider 超时
  20s+，caller 为本应用），说明当时 GMS 处于异常状态，passkey 依赖 GMS，
  这种情况下会表现为卡死/被系统回收。重启后恢复正常。
- 加固：插件里 `setWebAuthenticationSupport` 的调用已包 try/catch，
  provider 抛异常不会升级为应用崩溃。

### 地址栏改为键盘上方内联输入条（2026-11-28）

点击导航头不再弹底部 sheet，而是：

- 页面底部（Scaffold 随键盘缩小）出现一条 **输入条**：地球图标 + 输入框 + 「→」打开按钮
- 输入关键词时的必应建议显示在 **输入框上方**（同一个组件内，向上展开）
- 点建议 / 点「→」/ 键盘回车都会提交；点击页面遮罩或按返回关闭
- 输入网址（含 `.` 且无空格）不请求建议
- 移除旧的 `showWebInputSheet` 底部弹层

测试：`test/web_address_bar_test.dart`（建议位于输入框上方、点建议提交、
箭头提交、网址不请求建议）。
