# GStore A2UI 调研与应用报告

> 调研时间：2026-11-27
> 调研对象：<https://github.com/a2ui-project/a2ui>（commit `36725eee`，2026-11-26）
> 当前 GStore 基线：Flutter 3.50.1 / Dart 3.14.0，`main` 已合并 3.50 升级
> 结论先行：**A2UI 与 GStore 的 AI 助手高度契合，建议按「独立 Canvas PoC → 工具式接入 → 对话内联」三阶段推进，不要一次性改主聊天链路。**

---

## 1. 执行摘要

A2UI 是 Google 的 Agent-to-User Interface 协议：Agent 输出结构化 UI 描述，客户端用自己的原生组件渲染。它不执行模型生成的代码，天然适合 GStore 这种「模型不可信 + 需要保持自有设计系统」的场景。

本次完成的工作：

1. 安装了 A2UI 官方 coding-agent skill 到 GStore：
   ```text
   .agents/skills/a2ui/SKILL.md
   ```
2. 通读协议 v1.0、Flutter renderer、Dart Agent SDK、basic catalog 与 conformance 资料。
3. 在当前 Flutter 3.50.1 下实测依赖解析、APK 体积、prompt token 成本。
4. 对照 GStore 现有 Agent 架构，给出三种接入方案、场景分级、安全约束和工期预估。

关键实测数据：

| 项目 | 结果 |
|---|---|
| 最新版本 | `a2ui_flutter 0.5.0` / `a2ui_core 0.9.0` / `a2ui_agent 0.5.0` |
| SDK 要求 | Flutter ≥ 3.47 / Dart ≥ 3.13 |
| 当前 GStore | Flutter 3.50.1 / Dart 3.14 → **已满足** |
| 依赖解析 | 成功，新增约 25 个依赖 |
| APK 体积增量（最小 App 实测） | **+658,408 B ≈ +0.63 MB（+4.4%）** |
| Basic catalog prompt（Express，v1.0） | **23,524 字符 ≈ 5.9k tokens** |
| 裁剪 catalog（14 组件 / 12 函数） | **20,680 字符 ≈ 5.2k tokens** |
| Direct JSON 格式 prompt | **43,982 字符 ≈ 11k tokens** |
| 硬依赖 | `video_player`（即使用不到视频也会进包） |

**建议路线：C → A → B**

- **C（独立 Canvas）**：0.5–1 天，验证协议、主题、中文、表单和性能。
- **A（工具式 `renderA2ui`）**：3–5 天，风险可控，复用现有工具消息渲染。
- **B（对话内联流式 surface）**：1–2 周，体验最好，但会动聊天核心链路和持久化。

---

## 2. 调研方法与环境

### 2.1 Skill 安装

A2UI 仓库提供的官方 coding-agent skill：

```text
skills/a2ui/SKILL.md
```

已复制到项目级 skills 目录：

```text
.agents/skills/a2ui/SKILL.md
```

该 skill 的作用是指导编码 Agent：

- 不要凭记忆写 A2UI（协议有 v0.8 / v0.9 / v0.9.1 / v1.0 多个版本）
- 优先读已安装包的 README 和 <https://a2ui.org/llms.txt>
- Flutter 使用 `a2ui_flutter` + `a2ui_core`，不要使用已废弃的 `genui` / `genui_a2ui`

> 注意：这个 skill 是给「开发 GStore 的 Agent」用的，不是给 GStore 运行时模型用的。运行时模型看到的 prompt 由 `a2ui_agent` 的 `promptSnippet` 生成。

### 2.2 实测环境

- Flutter 3.50.1 stable / Dart 3.14.0
- `a2ui_flutter 0.5.0`
- `a2ui_core 0.9.0`
- `a2ui_agent 0.5.0`
- Basic catalog v1.0 JSON：`catalogs/basic/v1/catalog.json`

依赖解析在独立临时工程完成，未改动 GStore 主依赖。

---

## 3. A2UI 协议与生态

### 3.1 核心模型

```text
Agent/LLM
  → 输出 A2UI 消息（JSON 或 Express DSL）
  → 客户端 MessageProcessor 校验、维护 surface 状态
  → Flutter 用原生组件渲染
  → 用户操作产生 action 消息回传给 Agent
```

四个核心概念：

| 概念 | 说明 |
|---|---|
| **Surface** | 一块可独立创建、更新、删除的 UI 区域 |
| **Catalog** | 客户端允许渲染的组件/函数白名单 |
| **Data Model** | surface 内的数据，支持 JSON Pointer 双向绑定 |
| **Action** | 按钮等交互回传给 Agent 的事件 |

### 3.2 协议 v1.0 消息类型

Agent → Renderer：

| 消息 | 作用 |
|---|---|
| `createSurface` | 创建 surface，可同时携带初始 `components` 和 `dataModel` |
| `updateComponents` | 更新组件邻接表 |
| `updateDataModel` | 更新数据模型（支持 JSON Pointer 路径） |
| `deleteSurface` | 删除 surface |
| `callRendererFunction` | Agent 调用 renderer 侧函数（v1.0 新增） |
| `agentFunctionResponse` | 回答 renderer 发起的 `callAgentFunction` |

Renderer → Agent：

- `action`：用户交互
- `error`：渲染/校验错误
- `rendererFunctionResponse`：回答 `callRendererFunction`
- `callAgentFunction`：renderer 请求 Agent 执行函数（v1.0）

### 3.3 数据绑定与表单

- `{"@path": "/user/name"}`：绑定数据模型
- 输入组件（`TextField`、`CheckBox`、`Slider`、`ChoicePicker`、`DateTimeInput`）是**本地双向绑定**
- 用户输入**不会自动发网络请求**，只有 `Button` 的 action 才会把数据带回 Agent
- `createSurface.sendDataModel=true` 时，renderer 在每条回传消息的 metadata 里附带完整数据模型

### 3.4 执行边界与安全设计

v1.0 明确定义了函数执行边界：

- `allowedCallers`: `rendererOnly` / `agentOnly` / `rendererOrAgent`
- `requiresUserActivation`: 例如 `openUrl` 必须由用户手势触发
- Agent 发起的 `callRendererFunction` 如果越过边界、参数不合法或缺少用户激活，renderer 必须拒绝并返回 `INVALID_FUNCTION_CALL`
- 嵌套 `@call` / `${...}` 有最大求值深度限制

这些规则是客户端实现安全策略的基础，但不能替代 GStore 自己的业务白名单。

### 3.5 Basic Catalog

v1.0 basic catalog 包含 18 个组件：

```text
布局：Column / Row / List / Card / Tabs / Modal / Divider
内容：Text / Image / Icon / Video / AudioPlayer
输入：Button / TextField / CheckBox / ChoicePicker / Slider / DateTimeInput
```

14 个函数：

```text
required / regex / length / numeric / email
formatString / formatNumber / formatCurrency / formatDate / pluralize
openUrl / and / or / not
```

Flutter 侧：

```dart
final processor = MessageProcessor<ComponentImplementation>(
  catalogs: [basicCatalog(locale: 'zh-CN', openUrl: ...)],
  outboundListener: sendToAgent,
  unifiedOutbound: true,
);

A2uiSurface(surface: surface)
```

注意：

- basic catalog 是 **Material 组件**，放在 `MaterialApp` / `Material` 下
- v1.0 移除了硬编码主题色，颜色/字体主要跟随 `Theme.of(context)`
- spacing / radius / 品牌组件仍需自定义 catalog
- `openUrl` 默认不传回调时不可用，传了要自己做 URL 白名单

---

## 4. 包与成本实测

### 4.1 版本与依赖

| 包 | 版本 | SDK 约束 | 主要依赖 |
|---|---|---|---|
| `a2ui_flutter` | 0.5.0 | Flutter ≥3.47 / Dart ≥3.13 | `a2ui_core`、`video_player`、`path_parsing` |
| `a2ui_core` | 0.9.0 | Dart ≥3.13 | `preact_signals`、`intl`、`json_schema_builder` |
| `a2ui_agent` | 0.5.0 | Dart ≥3.13 | `a2ui_core`、`antlr4` |

### 4.2 APK 体积

用最小 Flutter App 实测（同一工程，加依赖前后各构建一次 arm64 release）：

```text
基线：15,045,227 B (15.0 MB)
加 A2UI：15,703,635 B (15.7 MB)
增量：+658,408 B ≈ +0.63 MB (+4.4%)
```

增量主要来自：

- `video_player_android`（ExoPlayer / media3）
- `a2ui_core` 的 `json_schema_builder` / `preact_signals`
- `antlr4`（Agent 侧 Express 解析）

GStore 当前 arm64 release 约 72.3 MB，预计增量在 **0.6–1.0 MB** 量级，可接受。

> 即使只做文本/表单，`video_player` 也会被 `a2ui_flutter` 硬依赖带进来。若非常在意体积，需要自定义 renderer 或 fork 去掉 `Video`/`AudioPlayer` 组件，但依赖树仍在。

### 4.3 Prompt 成本

用 `a2ui_agent` 生成 basic catalog 的 `promptSnippet`：

| 格式 | 字符数 | 约 tokens（chars/4） |
|---|---|---|
| Express（默认） | 23,524 | ~5,900 |
| 裁剪 catalog（14 组件 / 12 函数） | 20,680 | ~5,200 |
| Direct JSON | 43,982 | ~11,000 |

结论：

- **Express 比 Direct JSON 省约一半 prompt**，应作为默认
- 裁剪组件/函数只省约 12%，因为格式说明和示例占大头
- 每轮都注入 5–6k tokens 对 GStore 的上下文预算有明显影响
- 建议按需注入：只有用户明确要「生成界面/表单/卡片」时，或进入 Canvas 模式时才加 A2UI prompt

---

## 5. GStore 现状与接入点

### 5.1 现有 Agent 链路

```text
AgentService.chat()
  → _runAgentLoop()
  → _generateStep()（Genkit 流式文本 + 工具调用）
  → AgentMessage + ValueNotifier
  → AgentChatListView 渲染
  → Rust AgentStore 持久化
```

关键代码位置：

| 位置 | 作用 |
|---|---|
| `lib/core/agent/agent_service.dart:6187` | `chat()` |
| `lib/core/agent/agent_service.dart:5846` | `_runAgentLoop()` |
| `lib/core/agent/agent_service.dart:5966` | `_generateStep()` 流式 chunk 回调 |
| `lib/core/agent/agent_service.dart:160` | `AgentMessage` UI 模型 |
| `lib/core/agent/agent_session_store.dart:59` | `SessionMessage` 持久化模型 |
| `lib/core/agent/agent_prompt.dart:38` | `AgentPrompt.build()` 系统提示词 |
| `lib/core/agent/agent_tool_spec.dart:217` | `AgentToolCatalog` 工具注册表 |
| `lib/core/agent/agent_tool_module.dart:71` | `AgentToolModule` 可插拔工具 |
| `lib/page/agent/chat_list_view.dart:31` | `AgentChatListView` |
| `lib/page/agent/chat_list_view.dart:185` | `_buildItemWidget()` |
| `lib/page/agent/chat_list_view.dart:735` | `_buildToolOrControl()` |
| `lib/page/agent/chat_list_view.dart:324` | `_signatureOf()` 重建签名 |
| `rust/gstore_core/src/agent/store.rs:42` | Rust `AgentMessage` 行结构 |
| `rust/gstore_core/src/agent/store.rs:669` | `INSERT INTO agent_message ...` |
| `rust/gstore_core/src/migration.rs:20` | `CORE_SCHEMA_VERSION` 迁移入口 |

### 5.2 现有渲染机制的关键约束

`AgentChatListView` 有严格的 widget 缓存：

- 每个 item 按 `key` 缓存 Widget 实例
- `_signatureOf()` 只包含 `text.length`、`reasoning.length`、`toolStatus`、下载进度等
- **A2UI surface 更新如果只改 surface 内部状态，不会触发列表 item 重建**

因此内联方案必须：

1. 给 `AgentMessage` 增加 surface 版本/修订号
2. 把 revision 写进 `_signatureOf()`
3. 或者让 surface 自己用 `ValueListenable`/signals 驱动局部刷新，不依赖列表重建

### 5.3 持久化约束

`agent_message` 表是固定列：

```text
seq,time,is_user,text,reasoning,is_tool_result,tool_type,tool_status,
tool_detail,tool_name,tool_args,tool_result,turn_id,confirm_options,
confirm_multi_select
```

内联 A2UI 需要新增字段（例如 `a2ui_json`）并做 schema 迁移；工具式方案可以先把原始 A2UI JSON 放进已有的 `tool_result`，零迁移。

### 5.4 设计系统约束

GStore 的 AGENTS.md 明确要求：

- 禁止硬编码颜色/字号
- 统一使用 `Theme.of(context).colorScheme` / `textTheme`
- 弹层统一 `AppSheet` / `AppDialogs`
- 危险操作统一 `showConfirmSheet(isDangerous: true)`

Basic catalog 只保证 Material 风格，不保证 GStore 的：

- `AppSpacing`
- `AppRadius`
- `AppTypography`
- `AppCard` / `AppButton` / `AppTextField` 的视觉细节

所以产品化必须做 **GStore 自定义 catalog**，不能直接交付 basic catalog。

---

## 6. GStore 使用场景分级

### 6.1 最适合（建议优先）

| 场景 | A2UI 能做什么 | 价值 |
|---|---|---|
| 搜索结果 | 应用卡片列表、图标、版本、来源、操作按钮 | 比纯文本更直观，减少一轮工具调用 |
| 应用详情摘要 | 基本信息 + 安装/打开/详情按钮 | 快速操作，不必跳页 |
| 筛选/排序表单 | 条件选择、范围输入、提交 | 比多轮问答高效 |
| 备份/恢复摘要 | 备份内容统计、恢复模式选择 | 结构化展示 |
| 请求调试环境变量 | 表单 + 校验 + 提交 | 替代逐项问答 |
| 代理诊断 | 连接状态、接口、规则摘要 | 可读性提升 |
| 模块管理 | 模块列表、状态、安装按钮 | 状态可视化 |

### 6.2 有条件适合

| 场景 | 限制 |
|---|---|
| 配置修改 | 敏感项必须走原生 `showConfigControl` / `confirmAction`，A2UI 只做展示 |
| 下载/安装进度 | 现有工具卡片已经很好；A2UI 只适合做汇总，不适合高频进度 |
| 性能调优 | 涉及 root/温控/CPU，必须原生确认，不能让模型直接下指令 |
| 证书/代理安装 | 安全敏感，A2UI 只展示步骤，不执行 |

### 6.3 不适合

- 卸载、删除、安装确认：**绝不**用 A2UI 界面做最终确认，继续用原生 `AppDialogs.showConfirmSheet`
- 整页导航、复杂图表、长视频：用原生页面
- 超大列表/深层嵌套/外部图片：容易拖垮 UI
- 本地小模型：DSL 遵循率低，优先降级为纯文本

---

## 7. 三种接入方案

### 方案 C：独立 Canvas（推荐先做）

```text
AI 助手菜单 → 「生成式界面」
  → A2uiLabPage（独立页面）
  → 静态 A2UI JSON / 简单输入
  → MessageProcessor + A2uiSurface
```

特点：

- 不动聊天链路、不动持久化
- 可以快速验证主题、中文、表单、列表性能
- 安全边界清晰
- 适合作为 PoC 和后续「Canvas 模式」的基础

建议先验证：

1. GStore 主题下 basic catalog 的视觉
2. 中文文本、日期、数字格式（`locale: 'zh-CN'`）
3. 20–50 项列表滚动性能
4. 表单双向绑定和 action 回传
5. 错误 surface / 非法消息的降级

### 方案 A：工具式 `renderA2ui`（第一版产品化）

```text
模型调用 renderA2ui(payload)
  → 校验 A2UI 消息
  → 在工具消息卡片中渲染 A2uiSurface
  → 用户操作 → action 作为下一轮用户消息/工具结果回传
```

GStore 侧改动：

1. 新增工具模块（`AgentToolModule`）或 `AgentToolSpec`：

   ```text
   name: renderA2ui
   params:
     payload: string   // A2UI Express 或 JSON
     format: string    // express | json
     title: string?
   ```

2. 执行器里用 `a2ui_core` 校验并创建 surface，把原始消息存到工具结果：

   ```text
   toolResult = {"a2ui": [...messages], "version": "1.0"}
   ```

3. `_buildToolOrControl()` 增加分支：

   ```dart
   if (msg.toolName == 'renderA2ui' && msg.toolStatus == done) {
     return A2uiToolCard(payload: msg.toolResult);
   }
   ```

4. action 回传：把 action 包成一条用户消息（或工具响应），走现有 `AgentService.chat()`。

优点：

- 不改流式文本、工具循环、消息表
- 复用现有工具消息持久化
- 容易回滚

缺点：

- 不是真正的流式 UI
- UI 和工具调用混在一起
- 模型需要把 UI 塞进工具参数，token 开销大
- 依赖 function calling；GStore 对本地 loopback 模型默认关闭工具

### 方案 B：对话内联流式 surface（长期）

```text
_generateStep() 流式 chunk
  → a2ui_agent openStream()
  → ResponsePart: text | messages
  → AgentMessage 增加 a2ui 字段
  → AgentChatListView 渲染 surface
  → action → 下一轮
```

GStore 侧需要改：

1. `AgentMessage` 增加：
   - `List<Object>? a2uiMessages`
   - `int a2uiRevision`
   - 或 `A2uiSurfaceState? a2uiSurface`
2. `_signatureOf()` 加入 `a2uiRevision`
3. `_buildItemWidget()` 增加 surface 分支
4. `SessionMessage` 增加 `a2uiJson` 字段
5. Rust `AgentMessage` + `agent_message` 表增加列，提升 `CORE_SCHEMA_VERSION`
6. action 回传与 `confirmAction` 的优先级、seq 排序重新设计
7. 持久化保存**原始 A2UI 消息**，恢复时重放，不保存 Widget/SurfaceModel

优点：

- 体验最好，接近「边生成边渲染」
- 文本和 UI 可以在同一条回复里混排

缺点：

- 动聊天核心链路
- 缓存/重建/seq 复杂
- 模型必须稳定输出 A2UI 块
- 持久化迁移成本高

### 方案对比

| 维度 | C Canvas | A 工具式 | B 内联 |
|---|---|---|---|
| 改动范围 | 新页面 | 工具 + 渲染分支 | 聊天链路 + 持久化 |
| 风险 | 低 | 中 | 高 |
| 体验 | 独立页面 | 工具卡片 | 流式混排 |
| 持久化 | 可选 | 复用 toolResult | 需要新列 |
| 适合阶段 | PoC | 第一版 | 成熟后 |

---

## 8. 设计系统适配

### 8.1 Basic catalog 的局限

- 组件是 Material 默认实现
- 只跟随 `Theme.of(context)` 的颜色/字体
- 不映射 GStore 的 `AppSpacing` / `AppRadius` / `AppTypography`
- 不保证 `AppCard` / `AppButton` 的视觉与交互

### 8.2 推荐做法：GStore 自定义 catalog

先保留 basic catalog 的 schema 和函数，替换组件实现：

```dart
final gstoreCatalog = basicCatalog(locale: 'zh-CN').derive(
  id: 'https://gstore.app/a2ui/catalog/v1',
  components: [
    ComponentImplementation(
      name: 'Card',
      schema: ...,
      builder: (context, node, props, buildChild) => AppCard(...),
    ),
    ComponentImplementation(
      name: 'Button',
      schema: ...,
      builder: (context, node, props, buildChild) => AppButton(...),
    ),
    // Text / Column / Row / List / TextField ...
  ],
);
```

组件映射建议：

| A2UI | GStore |
|---|---|
| `Card` | `AppCard` |
| `Button` | `AppButton`（primary/secondary/danger） |
| `TextField` | `AppTextField` |
| `ChoicePicker` | `AppSegmentedButton` / `AppPillToggle` |
| `Tabs` | `AppTabBar` |
| `Modal` | `AppSheet` |
| `List` | `ListView.builder` + `AppCard` |
| `Text` | `AppTypography` 对应样式 |

### 8.3 第一阶段可以先用 basic catalog

PoC 阶段不必立刻做完整自定义 catalog：

- 用 `basicCatalog(locale: 'zh-CN')` 快速看效果
- 确认「生成式 UI 是否值得做」
- 再做组件映射和视觉统一

---

## 9. 安全模型

A2UI 官方明确：**Agent 输出是不可信输入**。GStore 还允许用户配置任意 OpenAI 兼容端点，因此必须默认不信任。

### 9.1 硬性约束

1. **只注册白名单 catalog**
   - 不开放任意 Widget
   - 第一阶段禁用 `Video` / `AudioPlayer` / `DateTimeInput`（如不需要）
2. **危险操作绝不用 A2UI 确认**
   - 卸载、删除、安装、root、代理证书等继续用原生 `showConfirmSheet`
3. **action 白名单**
   - A2UI action 只能映射到受控动作：
     - `open_app_detail`
     - `prefill_search`
     - `show_native_confirm`
     - `refresh_surface`
   - 不允许直接执行卸载/安装/删除
4. **`openUrl` 默认关闭**
   - 开启时只允许 `https` + 域名白名单
   - 必须由用户手势触发
5. **输入限制**
   - surface 数量 ≤ 2
   - 组件数 ≤ 80–100
   - 嵌套深度 ≤ 10–12
   - 列表项 ≤ 50
   - 文本长度 ≤ 2,000 字符
   - 图片只允许 https + 域名白名单，禁止 data URI
6. **数据模型不含密钥**
   - 不把 token、cookie、密码放进 A2UI data model
   - `sendDataModel` 只在必要时开启
7. **错误与审计**
   - 记录 A2UI 校验错误、action、surface 生命周期
   - 日志带 `turnId` / `sessionId`，便于排查

### 9.2 提示注入

- A2UI 消息本身是模型输出，可能包含诱导性文案
- 按钮文案不能作为授权依据
- action 必须经过本地白名单和参数校验
- 不要把用户隐私数据放进 surface 再回传给模型

---

## 10. 性能与多模型兼容

### 10.1 Prompt 成本

- Express：约 5.9k tokens / 次
- 裁剪 catalog：约 5.2k tokens / 次
- Direct JSON：约 11k tokens / 次

建议：

- 默认 Express
- 只在「生成界面」意图或 Canvas 模式下注入 A2UI prompt
- 普通聊天不注入，避免每轮多 5–6k tokens
- 监控 `AgentTurnTrace.promptChars` 和 token 统计

### 10.2 渲染性能

- `AgentChatListView` 已有 widget 缓存，surface 更新必须走 revision 或局部 signals
- 流式渲染要节流（例如 50ms 一次），避免每个 chunk 重建整棵树
- 列表用 `List` 组件的模板能力，避免一次生成大量组件
- 图片加载走现有缓存，限制尺寸和域名

### 10.3 多 Provider

A2UI 输出是文本，理论上所有模型都能用：

- Gemini / OpenAI / DeepSeek：Express 遵循率通常较好
- 本地小模型：可能无法稳定输出 DSL
  - 可降级为 Direct JSON（prompt 翻倍）
  - 或只在用户明确要求时启用
- 工具式方案依赖 function calling
  - GStore 对本地 loopback 模型默认关闭工具
  - 因此内联文本方案对小模型更友好

必须按 provider 做遵循率评估，不能假设所有模型都一样。

---

## 11. 测试与评估计划

### 11.1 PoC 验收

- GStore 主题下 basic catalog 视觉可接受
- 中文文本、日期、数字格式正确
- 表单双向绑定 + action 回传
- 50 项列表滚动无明显掉帧
- 非法消息/超限 surface 能降级不崩溃

### 11.2 单元/Widget 测试

- A2UI 消息校验（合法/非法/越界）
- action 白名单映射
- surface 生命周期（create/update/delete）
- `_signatureOf` 包含 revision 后缓存正确失效
- Golden test：A2UI JSON → Widget 树（浅色/深色/中文）

### 11.3 协议一致性

A2UI 仓库自带 conformance 套件：

```text
conformance/agent/direct_json
conformance/agent/express
conformance/agent/*.yaml
```

`a2ui_agent` 自身测试已覆盖这些套件；GStore 侧重点测「消息 → 渲染 → action」闭环。

### 11.4 模型评估

- 每个 provider 选 5–10 个代表性 prompt：
  - 搜索结果卡片
  - 应用详情 + 操作
  - 筛选表单
  - 备份摘要
  - 错误/空态
- 指标：
  - 首次有效 surface 时间
  - 生成成功率（无校验错误）
  - action 正确率
  - token 成本
  - 用户是否更少跳页/更少追问

---

## 12. 风险清单

| 风险 | 等级 | 说明 | 缓解 |
|---|---|---|---|
| 0.x API 不稳定 | 高 | 0.4→0.5 已出现 SDK/breaking 变化 | 锁定版本，隔离封装 |
| Prompt 成本高 | 中 | 5–6k tokens/轮 | 按需注入、裁剪 catalog |
| 模型遵循率差异 | 高 | 小模型可能生成非法 DSL | 按 provider 评估、降级纯文本 |
| 设计系统不一致 | 中 | basic catalog 不是 GStore 视觉 | 自定义 catalog |
| 安全边界 | 高 | 模型可伪造 UI/动作 | 白名单 + 原生确认 |
| 持久化迁移 | 中 | 内联方案要加列 | 先做工具式，复用 toolResult |
| `video_player` 硬依赖 | 低 | 不用视频也进包 | 接受 +0.6–1MB |
| 无障碍 | 中 | intrinsic size / label 限制 | 自定义组件时补齐 |
| 中文格式 | 低 | 需要 `locale: 'zh-CN'` | PoC 验证 |

---

## 13. 推荐路线与工作量

### 阶段 0：独立 Canvas PoC（0.5–1 天）

- 新建 `A2uiLabPage`（不接 Agent）
- 静态 A2UI JSON + basic catalog
- 验证主题、中文、表单、列表性能、错误处理

**决策门**：视觉和性能是否值得继续。

### 阶段 1：工具式 `renderA2ui`（3–5 天）

- 新增工具模块 + 参数 schema
- 用 `a2ui_core` 校验
- 工具消息卡片渲染 `A2uiSurface`
- action 回传
- 复用 `toolResult` 持久化

**决策门**：模型是否能稳定生成有价值 UI；action 闭环是否可靠。

### 阶段 2：对话内联流式（1–2 周）

- 接入 `a2ui_agent` `openStream`
- `AgentMessage` / `SessionMessage` / Rust 表结构扩展
- 缓存签名 + surface revision
- 流式节流
- action 与 confirmAction 优先级

**决策门**：聊天链路复杂度和性能是否可接受。

### 阶段 3：产品化（1–2 周）

- GStore 自定义 catalog
- 设计系统适配
- 安全限制/审计
- 多 provider 评估
- Golden/集成测试

### 总工期

| 阶段 | 乐观 | 保守 |
|---|---|---|
| PoC | 0.5 天 | 1 天 |
| 工具式 | 3 天 | 5 天 |
| 内联 | 1 周 | 2 周 |
| 产品化 | 1 周 | 2 周 |

---

## 14. 结论

**A2UI 值得做，但不适合一次性重构聊天链路。**

- 协议方向正确：结构化 UI、客户端原生渲染、不执行模型代码
- 与 GStore 的 AI 助手、工具系统、设计系统约束高度契合
- 当前 Flutter 3.50.1 已满足 0.5.0 要求，依赖解析和构建验证通过
- 成本可控：APK +0.6–1MB，prompt +5–6k tokens/轮
- 最大风险不是技术，而是**模型遵循率**和**安全边界**

建议从 **Canvas PoC** 开始，用 0.5–1 天验证「值不值得做」，再用工具式方案用 3–5 天验证「模型能不能稳定生成」，最后才考虑内联流式。

---

## 附录 A：关键 API 速查

```dart
// Renderer
final processor = MessageProcessor<ComponentImplementation>(
  catalogs: [basicCatalog(locale: 'zh-CN', openUrl: onOpenUrl)],
  outboundListener: (message) => send(message.toJson()),
  unifiedOutbound: true,
);

processor.model.onSurfaceCreated.subscribe((surface) => ...);
processor.model.onAction.subscribe((action) => ...);

processor.processMessages(json);
A2uiSurface(surface: surface);

// Agent
final generator = A2uiGenerator(catalogs: [
  CatalogConfig.fromPath(
    'catalogs/basic/v1/catalog.json',
    protocolVersion: A2uiProtocolVersion.v1_0,
  ),
]);
final processor = generator.createProcessor(rendererCapabilities);
final snippet = processor.promptSnippet;

final stream = processor.openStream();
for (final chunk in llmStream) {
  stream.feed(chunk).forEach(deliver);
}
stream.close().forEach(deliver);
```

## 附录 B：参考

- 仓库：<https://github.com/a2ui-project/a2ui>
- 协议 v1.0：`specification/v1_0/docs/a2ui_protocol.md`
- Flutter renderer：`dart/a2ui_flutter/README.md`
- Agent SDK：`dart/a2ui_agent/README.md`
- Basic catalog：`catalogs/basic/v1/catalog.json`
- Skill：`.agents/skills/a2ui/SKILL.md`
- pub.dev：
  - <https://pub.dev/packages/a2ui_flutter>
  - <https://pub.dev/packages/a2ui_core>
  - <https://pub.dev/packages/a2ui_agent>

---

## 15. 阶段 A 实现记录（2026-11-27）

### 已实现

新增 Agent 工具：

```text
renderA2ui(payload, title?)
```

流程：

```text
模型调用 renderA2ui
  -> A2uiRenderValidation 校验（协议/白名单/限额）
  -> 原始 payload 写入 toolArgs
  -> 工具消息卡片 A2uiToolCard 渲染 surface
  -> 用户点击按钮
  -> action 转成一条用户消息回传 Agent
```

### 校验规则

`lib/core/agent/a2ui_render_validation.dart`：

- 只接受 A2UI v1.0：`createSurface` / `updateComponents` /
  `updateDataModel` / `deleteSurface`
- `catalogId` 必须是 basic catalog
- 组件白名单：
  `Column / Row / Card / Text / Button / Divider / TextField / CheckBox /
  ChoicePicker / List`
- 拒绝 `Image / Video / AudioPlayer / Tabs / Modal / Slider / DateTimeInput`
- 拒绝 local `functionCall` / `openUrl`
- 拒绝 `sendDataModel=true`
- 限制：1 个 surface、≤60 组件、payload ≤32,000 字符、字符串 ≤2,000 字符
- 最后用 `a2ui_core` 做完整协议校验（组件引用、绑定、schema）

### 渲染与交互

`lib/page/agent/a2ui_tool_card.dart`：

- 工具消息卡片内渲染 `A2uiSurface`
- action 通过 `AgentChatListView._a2uiToolCard` 回传
- 回传文本示例：
  ```text
  我已点击 A2UI 界面中的“安装”按钮（action=install_app，context={"package":"com.termux"}）。请根据这个操作继续。
  ```
- 工具运行中/生成中禁用交互
- 会话恢复时从 `toolArgs.payload` 重新渲染，无需新增数据库列

### 工具类型

- `AgentToolType.a2ui`：图标 `layout_grid`，标签「生成界面」
- 系统提示词工具目录 + `loadProtocol('renderA2ui')` 提供完整契约

### 使用方式

1. 在 AI 设置中配置支持 function calling 的模型
2. 对助手说：
   - 「用卡片展示 Termux 的信息，带安装和查看详情按钮」
   - 「用表单帮我筛选开源的工具类应用」
   - 「把已安装应用的前 5 个渲染成列表」
3. 模型应调用 `renderA2ui`；首次可能先调用
   `loadProtocol(target="renderA2ui")`
4. 点击卡片按钮后，action 会作为用户消息回传，模型继续下一轮

### 当前限制

- 必须使用支持工具调用的模型；本地小模型默认关闭 function calling
- 模型遵循 A2UI JSON 的程度需要按 provider 实测
- 工具 description 只给摘要，完整契约按需 `loadProtocol`
- 阶段 A 不做流式 surface、不做聊天内联混排；这些留给阶段 B

### 测试

```text
test/a2ui_render_validation_test.dart   8 项
test/a2ui_tool_card_test.dart           3 项
test/agent_a2ui_tool_test.dart          3 项
test/a2ui_lab_page_test.dart            4 项
```

覆盖：合法/非法 payload、组件白名单、action 回传、禁用态、工具注册。
