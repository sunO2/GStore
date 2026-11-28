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
