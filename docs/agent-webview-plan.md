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
