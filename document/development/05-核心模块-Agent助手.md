# 核心模块：Agent 助手

> 开发 Wiki 第五篇 · Genkit 集成、工具协议注册表、按需协议加载、思考内容

## 1. 模块结构

```
lib/core/agent/
├── agent_service.dart       # 核心服务（Genkit 集成、工具注册、会话管理、流式/思考解析）
├── agent_tool_spec.dart     # ★ 工具协议注册表（单一事实来源：分组/简介/完整协议/参数/敏感动作）
├── agent_tool_module.dart   # 工具模块抽象（可插拔）与执行上下文
├── tools/builtin_tools.dart # 内置工具模块（由注册表派生，无重复声明）
├── think_parser.dart        # 内联 think 标签解析（可测试纯函数）
├── agent_model_store.dart   # 模型配置存储（Gemini / OpenAI 兼容）
├── agent_session_store.dart # 会话持久化（多会话、分页、工具参数/结果/思考）
├── agent_prompt.dart        # 系统提示词构建器（由注册表生成，运行时中文）
├── agent_skills.dart        # 技能库（中英双语：目录 + 按需完整工作流）
├── platform_arch.dart       # 设备架构检测与平台描述
lib/page/agent/              # 聊天 UI（时间轴、思考折叠块、确认节点、工具胶囊）
```

## 2. 模型配置（agent_model_store.dart）

| 项 | 说明 |
| --- | --- |
| Provider | `google`（Gemini）、`openai`（OpenAI 及兼容服务） |
| 默认模型 | gemini-2.0-flash / gpt-4o-mini |
| 存储 | SharedPreferences（键 `agent_models` / `agent_selected_model_id`） |
| CRUD | add / update / remove / select / clearAll |
| 开关 | `toolsEnabled`（工具调用降级）、`showReasoning`（是否展示思考过程） |

## 3. 会话持久化（agent_session_store.dart）

- `AgentSession`：会话（id / title / createdAt / updatedAt / messages）。
- `SessionMessage`：消息 + 工具字段（toolName / toolArgs(JSON) / toolResult / toolDetail）
  + `reasoning`（思考内容）+ seq + turnId。新增字段均为可选，**旧数据可直接反序列化**。
- `AgentSessionStore`：多会话管理、历史分页加载。

### 历史分页

- 首次加载 `initialTurnsCount = 5` 个**完整回合**（以用户消息为锚点，避免切分对话）。
- `loadMoreHistory()` 每次补全一组完整对话，返回新增消息供 UI 增量同步。
- 恢复顺序：`time` 为主、`seq` 为辅；重启后 `seq` 计数器推进到历史最大值 + 1。

## 4. 工具协议注册表（agent_tool_spec.dart）★

### 4.1 为什么需要它

改造前工具元数据在 **4 处各写一遍**（`AgentPrompt`、`AgentService._systemPrompt`、
`_defineTools()`、`builtin_tools.dart`），已经出现漂移（`cacheManage` 曾漏登记，
导致同一工具走不同注册分支）。现在收敛为唯一来源。

### 4.2 数据结构

```dart
AgentToolSpec(
  name, group, label, brief, protocol,
  params, sensitiveActions, sensitiveNotes, alwaysSensitive, async, meta, enabled,
)
```

- `brief`：一行简介 → **常驻**系统提示词 + function-calling 描述（模型路由依据）
- `protocol`：完整协议（参数/规则/注意事项）→ **不常驻**，经 `loadProtocol` 按需读取
- `sensitiveActions` / `alwaysSensitive` → 生成敏感操作清单 + 运行期安全拦截判定

`AgentToolCatalog` 由 `kBuiltinToolSpecs` 惰性装载，并**派生**下列全部下游视图：

| 派生视图 | 用途 |
| --- | --- |
| `briefDirectory()` | 系统提示词的"工具目录"（分组 + 一行简介） |
| `enabled` | `_defineTools` / `buildActions` 的枚举源 |
| `sensitiveLines` | 系统提示词的敏感操作清单 |
| `protocolFor(name)` | `loadProtocol` 的数据源 |
| `isSensitiveCall(params)` | 运行期敏感工具拦截（原 `_isSensitiveTool` 硬编码 switch） |

### 4.3 自动注册与扩展

- 新增工具：**只需在 `kBuiltinToolSpecs` 增加一条协议声明**（或运行时
  `AgentToolCatalog.register(spec)`），提示词/defineTool/AiAction/敏感清单自动生效。
- `BuiltinAgentTools.all` 由注册表派生（排除 `meta` 工具），工具模块无需手写元数据。
- 上下线仍走模块体系：`AgentToolModule` 热插拔决定"模型可调用清单"，
  但元数据不再重复声明。

### 4.4 工具清单（分组）

| 分组 | 工具 |
| --- | --- |
| 发现与信息 | `searchApp` `getAppInfo` `updateApps` `installedApps` `fdroidRepo` |
| 获取与安装 | `downloadApp` `installApp` `manageDownload` |
| 管理与偏好 | `manageApp` `channelApp` `themeControl` `configManager` `backup` `webdavSync` `cacheManage` |
| 快照与版本分析 | `appSnapshot`（create/list/apps/detail/delete）`snapshotCompare` |
| 交互与扩展 | `confirmAction` `runJsChannel` |
| 元能力 | `loadProtocol`（按需读取工具/技能完整协议） |

### 4.4.1 快照 / 版本差异能力

`appSnapshot` 与 `snapshotCompare` 是"看出**版本更新改了什么**"的入口：

- 采集/持久化/对比/文本化全部收敛在 `lib/core/snapshot/snapshot_service.dart`
  （`AppSnapshotService`），UI 与 Agent 共用同一入口。
- `appSnapshot(create)` 只接 `packageName`+可选 `note`；**版本号与应用名一律由系统
  从真实 APK 读取**（见 `SnapshotCollector`），不接受调用方传值。
- `snapshotCompare` 省略 id 时对比该应用最近两份；指定 id 时按采集时间自动纠正为"旧 → 新"。
- `renderDiff()` 把结构化差异渲染成模型可读文本：结论 + 各节指纹判定 + 逐节明细
  （字段级 `− 旧` / `+ 新`、内容指纹是否同一文件、疑似改名）+ APK 体积差；
  每节条目数有上限（`maxEntriesPerSection`），并显式标注"不可比"分节。
- 配套技能「版本差异分析」规定了解读顺序（签名 → DEX/原生库 → 权限/组件/深链 → 体积）
  与"只陈述差异中的事实"的约束。

### 4.5 两套注册机制

1. **Genkit `ai.defineTool`**（云端 LLM 流式调用）——描述取 `spec.brief`。
2. **`AiAction` / `ActionController`**（原生工具执行 + 回调）——参数由 `spec.params` 生成，
   handler 统一委托 `_executeTool`；`downloadApp` 保留专用 handler（进度回调 + 终态续接）。

`confirmAction` 与 `loadProtocol` **不注册为 AiAction**：前者由 `_confirmAction` 内部处理，
后者由 `_defineTools` 直接读取注册表。

### 4.6 流式输出与思考

- 聊天采用 Genkit `generateStream` + `flutter_gen_ai_chat_ui`。
- 工具调用时，已输出文本被"定稿"为独立消息（`_commitActiveStreamText`，思考内容一并带走），
  实现 **"回复 → 工具 → 回复"** 时间线顺序。
- **思考内容**来源（逐条降级，任一命中即可）：
  1. 结构化 `ReasoningPart` —— 流式 `_extractReasoning`；
  2. 内联 ` thinking…<｜end▁of▁thinking｜>` —— `think_parser.splitThink`
     （大小写不敏感；分片未闭合时扣住标签不展示）；
  3. **最终响应事后补取**（`_backfillReasoning`）—— 仅兜底（非流式路径 /
     自建模型不可用 / 内联 think 未闭合等）。

#### 为什么需要自建 model provider（`openai_reasoning_model.dart`）

`genkit_openai 0.3.7` 的 `_handleStreaming` 实际上只做了一件事：

```dart
final textDelta = chunk.textDelta;   // = choices[0].delta.content
if (textDelta != null) ctx.sendChunk(... TextPart(text: textDelta) ...);
```

而 `openai_dart` 的 `delta` 上**逐片带着** `reasoningContent`（DeepSeek-R1 系）与
`reasoning`（OpenRouter 等）—— 也就是说**协议层本来就能流式，是插件没有转发**，
应用侧只能等生成结束再从最终响应 `raw` 里补取，表现为思考内容**整段出现**。

因此新增 `lib/core/agent/openai_reasoning_model.dart`，用 `Genkit.defineModel` 自建模型：

- 复用官方**已导出**的 `GenkitConverter`（消息 `toOpenAIMessages`、工具 `toOpenAITool`、
  回包 `fromOpenAIAssistantMessage`）→ 消息与**工具调用协议完全一致**；
- 只在流式循环里多补一条：reasoning delta → `ReasoningPart`
  （映射逻辑抽成纯函数 `openAiDeltaToParts`，可单测）；
- `Model` 本身即 `ModelRef`，`_getModelRef()` 直接返回它；
  **构建失败自动回退官方插件模型**（`_buildCustomModel` 捕获异常返回 null）；
- `pubspec.yaml` 因此把 `openai_dart` 提升为直接依赖（本就作为 `genkit_openai` 的传递依赖存在）。

Gemini 走 (1)，本来就是真流式。
- 无正文但有思考时消息**不删除**（否则用户看不到思考过程）。
- 停止生成：`_cancelRequested` 置位，同时取消进行中的下载任务。

### 4.7 确认交互（confirmAction）

- 敏感/不可逆操作（卸载、清数据、恢复备份、删除会话、移除应用等）**必须**先调用。
- 敏感判定来自注册表；页面不在前台时敏感操作被安全拦截。
- 支持多选一（`options`）与多选勾选（`multiSelect=true`）。

## 5. 系统提示词（agent_prompt.dart）

- **唯一提示词构建器**（运行时由 `AgentService.initialize()` 调 `useChinese()`），
  内容全部由注册表/技能库生成，不再硬编码工具清单。
- 内容：工具目录（分组 + 一行简介）、生成式敏感清单、技能目录、错误处理指引、使用规则。
- 提示词显式说明："不确定参数时先调用 `loadProtocol`"。

## 6. 技能库（agent_skills.dart）

- 每个技能含：名称（中/英）、触发场景、完整工作流（中/英）。
- 注入方式分两层：
  - `renderBriefs()` → 常驻"技能目录"（仅名称 + 触发场景）；
  - `protocolFor(key)` → 按需取完整工作流（经 `loadProtocol`，中/英文名均可定位）。
- `renderAll()` 保留（供 `loadProtocol(all)` 与测试使用）。
- 现有技能含「版本差异分析」（配合 `appSnapshot` / `snapshotCompare`，规定差异解读顺序）。

## 7. 聊天 UI（lib/page/agent/）

> 对话**不是**聊天框架自带的纯文本气泡，而是**自定义 step 时间轴**
> （`customBuilder` → `_TurnTimeline`）。因此框架不会帮忙渲染思考内容，
> 必须由 step 的文本节点自己渲染。

- **回合时间轴** `_TurnTimeline`：同回合 agent 文本 + 工具调用按执行顺序竖向展示，
  每个节点带序号圆点与竖线（step 结构，勿改）。
- **⚠ 两条同步路径必须样式一致（曾出过一次 bug）**：本页消息同步有两条路径——
  1. `_rebuildAll()` → `_groupTimeline()`：**agent 消息哪怕只有一条也会收进 `turnMsgs`**
     → `_toTimelineMessage()` → step 时间轴；
  2. `_onMessagesChanged()` 增量：新消息直接 `_toChatMessage()`。
  历史上 (2) 对助手文本返回的是**框架默认气泡**，导致"没有工具调用的一步回合"（纯问答）
  显示成默认气泡，与多步回合不一致。现已统一：`_toChatMessage()` 的助手分支同样返回
  `_TurnTimeline(turnMsgs: [msg])`（单条 = 1 步时间轴）。
  **新增助手消息呈现方式时，两条路径都要改。**
- **step 文本节点** = `step_text.dart` 中的公开组件（便于单独测试）：
  ```
  AgentStepTextBlock
  ├── [可选] AgentReasoningBlock   思考折叠块（受 showReasoning 开关控制）
  └── AgentMarkdownMessage         正文 Markdown（原有行为，保持不变）
  ```
  `_TurnTimeline._buildText` 与 `_toChatMessage`（无工具时的普通气泡）都走它，
  两条渲染路径行为一致。
- **思考折叠块** `AgentReasoningBlock`：流式中默认展开（实时可见）、结束后默认折叠，
  标题栏整行可点击切换。
- **工具详情**（`_buildToolDetailText`，时间轴节点与工具卡共用）：工具名/标识、状态、
  **耗时**、**调用参数（JSON）**、**执行结果**、下载状态；弹层可一键复制。
- **确认节点**：待确认时高亮问题 + 确认/取消（或多选一）按钮，选择后置灰展示结果。
- 历史分页：reverse 列表滚到视觉顶部触发 `loadMoreHistory`（分页期间禁止自动滚动）。

## 8. 相关测试

- `test/agent_tool_spec_test.dart`：★ 注册表唯一性/分组/目录/敏感判定/协议读取/运行时覆盖。
- `test/think_parser_test.dart`：内联 think 解析（完整/未闭合/分片/大小写/多段）
  + OpenAI raw 思考补取（两种字段名 / 结构异常不抛）。
- `test/agent_openai_reasoning_model_test.dart`：★ 流式 delta 映射
  （正文/reasoningContent/reasoning 单发与并发、思考优先、空 delta）。
- `test/agent_step_text_test.dart`：★ **自定义 step 文本节点** widget 测试——
  思考块渲染/折叠展开/开关关闭/正文不被改没。
- `test/snapshot_service_render_test.dart`：★ 差异文本化（结论 / 体积差 / 字段级 `−`+`+` /
  内容指纹结论 / 空差异 / 列表与详情渲染）。
- `test/agent_prompt_test.dart`：提示词构建、语言切换、生成式目录与清单。
- `test/agent_skills_test.dart`：技能双语渲染、完整性。
- `test/agent_tool_module_test.dart`：内置 19 工具由注册表派生、执行、上下线。
- `test/agent_model_store_test.dart`：模型配置与 Store CRUD 持久化。
- `test/agent_session_store_test.dart`：会话序列化、工具字段兼容。
- `test/agent_confirm_persist_test.dart` / `agent_download_progress_test.dart`：确认与下载进度。
- `test/agent_group_order_test.dart`：时间轴分组顺序。

## 9. 后续可完善（未闭环）

1. **动态工具子集**：当前 function schema 仍全量随请求发送，仅"提示词"做了瘦身；
   真正省 token 需按需下发工具集（分组激活 / 检索命中后注入）。
2. **自建模型的参数覆盖度**：`openai_reasoning_model.dart` 目前只透传
   `model/messages/tools`（本应用未使用 temperature 等自定义参数与 JSON 输出 schema）；
   若将来要让 Agent 调 temperature/结构化输出，需按 `chat.parseChatModelOptions`
   把 `request.config` / `request.output` 一并映射。
3. **工具调用遥测**：记录命中率/误选率/耗时分布，反向决定哪些工具常驻、哪些懒加载。
4. **思考块位置**：一轮内若发生工具调用，事后补取的思考内容挂在"本回合最后一条文本消息"上；
   若希望它固定显示在回合开头，需要按 turnId 聚合到首个文本节点。
   （自建模型上线后，思考内容已是流式挂到当时的流式消息上，此条主要影响兜底路径。）

## 10. 排查手册：`AIAgentResponse` 对话日志

日志查看器里搜 `AIAgentResponse` 即可过滤出完整一轮（`LogManager` 无 tag 字段，
用消息前缀实现）。每轮约 5–10 条，正文分片不逐条记（避免刷屏）。

| 事件 | 含义 |
|---|---|
| `▶ 请求` / `▶ 请求(续接)` | 本轮请求全貌：provider / model / baseUrl / **customModel** / showReasoning / 工具清单 / 完整消息 |
| `◆ 模型层发出思考分片` | **自建模型层**收到了 reasoning delta（证明协议层有数据） |
| `◆ 模型层流式汇总` | reasoningChunks / textChunks / finalReasoningLen |
| `◆ 思考分片开始(结构化)` | genkit 的 `ReasoningPart` 到达 AgentService |
| `◆ 思考分片开始(内联 think)` | 正文里的 ` thinking` 被解析出来 |
| `◆ 工具调用` / `◆ 工具结果` | 工具名 + 参数 + 结果 |
| `■ 响应` | 最终正文/思考长度与内容 + **rawProbe**（是否含 reasoning_content） |
| `⚠` / `✗` | 解析失败 / 生成失败（原先静默的 catch 已改为可见） |

**按日志判"思考内容为什么不显示"**

1. `customModel: false` → 自建模型没注册成功，走了官方插件 → 流式思考必丢。
2. 没有 `◆ 模型层发出思考分片` 且 `rawProbe.reasoningContentLen == 0`
   → **该端点/模型本次就没返回思维链**（非推理模型，或本地端点未实现 reasoning）——不是缺陷。
3. 有 `◆ 模型层发出思考分片`，但没有 `◆ 思考分片开始(结构化)`
   → 问题在 genkit chunk → App 这一段；看是否伴随 `⚠ 读取 chunk.content 失败`。
4. `■ 响应` 的 `reasoningLen > 0` 但界面仍不显示
   → 问题在渲染层（`showReasoning` 开关 / 时间轴 `AgentStepTextBlock`）。
