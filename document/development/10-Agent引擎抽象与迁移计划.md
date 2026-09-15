# 10-Agent 引擎抽象与迁移计划

> 状态：**规划中（未实施）** · 立项日期：2026-09-14 · 触发条件：见 [§6 前置待确认](#6-前置待确认阻塞项)
> 关联文档：[05-核心模块-Agent助手](./05-核心模块-Agent助手.md) · [08-核心模块-模块化框架](./08-核心模块-模块化框架.md) · [rust-flutter-async](./rust-flutter-async.md)
>
> **本文只登记计划、基线与判据，不含实施。** 实施前请先过 §6 的阻塞项。

---

## 1. 背景与目标

### 1.1 现状

Agent 的 LLM 编排当前直接绑在 **genkit** 上（`genkit` / `genkit_openai` / `genkit_google_genai`），
UI 与工具执行绑在 **flutter_gen_ai_chat_ui** 上。两者职责不同，但代码里没有明确边界。

### 1.2 动因

1. **引擎可替换**：避免被单一 SDK 锁死，给"换引擎 / 双引擎并存"留出低成本入口。
2. **现状已有补丁式特例**：genkit 的 OpenAI 兼容插件流式丢弃 `reasoning_content`，
   我们为此自建了一个 model provider（`openai_reasoning_model.dart`）。这类特例应该收在一个实现里，
   而不是散在业务层。
3. **特化逻辑混入业务**：`rawProbe`（探测 raw 里的思考字段）、`maxTurns`、provider 装配等
   SDK 细节目前写在 `AgentService` 内部。

### 1.3 目标

- 引入 **`AgentEngine` 事件流抽象**，把 genkit 收进 `GenkitEngine` 一个实现；
- 此后「替换 / 并存引擎」= **新增一个实现类**，而不是改动业务层；
- 顺带把 SDK 特化逻辑（自建 provider、rawProbe、装配）收拢。

### 1.4 非目标（明确不做）

- **不**引入外部 SDK 的 Sh 迷你 shell / Vfs / MCP / Subagents（本项目是应用商店助手，用不上，纯增面）；
- **不**替换本地推理：继续走 `gstore_mod_llm`（Rust llama.cpp）+ 现有本地端点；
- **不**改工具执行链路（`AiAction` / `ActionController`）与自定义 step 时间轴；
- **不**改会话 / 模型配置的持久化格式（如无必要）。

---

## 2. 现状耦合面（实测基线）

统计日期 2026-09-14，命令见 [附录 A](#附录-a耦合面复现命令)。

| 文件 | genkit 符号引用 | 说明 |
| --- | --- | --- |
| `lib/core/agent/agent_service.dart` | **104** | 编排核心：装配 / 定义工具 / 流式循环 / 结果处理 |
| `lib/core/agent/openai_reasoning_model.dart` | **20** | 自建 model provider（补 reasoning 流式） |
| `lib/core/agent/agent_session_store.dart` | 2 | 仅 `Message` / `Role` 类型 |
| `lib/core/agent/think_parser.dart` | 4 | 仅类型 |
| **合计** | **~130 处 / 4 个文件** | |

**耦合类别（共 5 类，全部集中在上面 4 个文件）**

1. provider 装配：`Genkit(plugins: [...])`、`googleAI(...)`、`openAI.model(...)`、`ai.defineModel(...)`
2. 工具声明：`ai.defineTool<Map<String, dynamic>, String>(...)`
3. 生成循环：`ai.generateStream<dynamic, void>(model/messages/toolNames/maxTurns)` + `stream.onResult`
4. 消息类型：`Message` / `Role` / `Part` / `TextPart` / `ReasoningPart`
5. 转换工具：`GenkitConverter.*`、`supportsTools(...)`

### 2.1 不属于 genkit 的部分（换引擎**不用动**）

这一节是成本能压下来的关键，实施前请勿误改：

| 区块 | 实际归属 | 证据 |
| --- | --- | --- |
| 工具注册/执行 `AiAction` / `ActionController` / `ActionParameter` / `ActionResult` | **flutter_gen_ai_chat_ui** | `flutter_gen_ai_chat_ui-2.15.0/lib/src/models/ai_action.dart:458` |
| 自定义 step 时间轴 | flutter_gen_ai_chat_ui 的 `customBuilder` + 本项目 `view.dart` / `step_text.dart` | — |
| 19 个工具的业务实现 | 本项目（`_executeTool` 分发） | — |
| 会话 / 模型持久化 | 本项目 sqflite | — |
| 工具协议注册表 | 本项目（`agent_tool_spec.dart`） | 换引擎时**只加一个适配器** |

> 结论：换引擎只需改「LLM 编排」这一层，工具执行与 UI 均不受影响。

---

## 3. 阶段计划

### P0 — 引擎抽象（先做，且与具体引擎无关）

> 这一步**即使最终不换引擎也值得做**：它把当前的特例与 SDK 细节收拢，且把将来换引擎的成本从
> "改 600–900 行"降到"新增一个实现类"。

**交付物**

- 新增 `lib/core/agent/engine/agent_engine.dart`
  - 事件类型（引擎无关）：
    | 事件 | 载荷 |
    | --- | --- |
    | `EngineTextDelta` | `text` |
    | `EngineReasoningDelta` | `text` |
    | `EngineToolCall` | `name` / `args` |
    | `EngineToolResult` | `name` / `ok` / `result` |
    | `EngineFinished` | `text` / `reasoning` / `finishReason` |
    | `EngineError` | `message` |
  - 接口草案：
    ```dart
    abstract class AgentEngine {
      String get id;                          // 'genkit' | '<other>'
      Future<void> initialize(AgentEngineConfig cfg);
      Stream<AgentEngineEvent> run(AgentRequest req);
      void cancel();
      void dispose();
    }
    ```
  - `AgentEngineConfig`：`provider` / `model` / `apiKey` / `baseUrl` / `toolsEnabled` / `showReasoning` / `platformDescription`
  - `AgentRequest`：`messages`（引擎无关的会话消息）/ `toolBriefs` / `maxTurns`
- 新增 `lib/core/agent/engine/genkit_engine.dart`：把现有 genkit 逻辑**原样迁入**
  （provider 装配、`_getModelRef`、`defineTool`、`generateStream` 循环、`stream.onResult`、
  reasoning 提取与事后补取、`rawProbe` 日志）。**行为必须保持不变。**
- `AgentService` 改为消费事件流：事件 → `AgentMessage` / `_commitActiveStreamText` / `_runAction`，
  不再直接出现 genkit API。

**事件 → 现有落点映射（实施对照表）**

| 事件 | 现有落点 |
| --- | --- |
| `EngineTextDelta` | `_applyStreamText()` → `AgentMessage.text` |
| `EngineReasoningDelta` | `AgentMessage.reasoning`（首片打 `AIAgentResponse` 日志） |
| `EngineToolCall` | `_runAction(name, args, detail:)` → 工具消息 |
| `EngineToolResult` | `_runAction` 结果 → `toolResult` + `◆ 工具结果` 日志 |
| `EngineFinished` | `_commitActiveStreamText()` / `_persistStreamMessage()` |

**涉及文件**：`agent_service.dart`（拆出约 600–900 行）、新增 3 个文件、
`agent_session_store.dart` / `think_parser.dart`（类型去 genkit 化）

**验收标准**

- [ ] `dart analyze lib` 0 error；agent 测试子集全绿（当前基线 121+）
- [ ] **行为等价回归**：改造前后各跑一轮，`AIAgentResponse` 日志逐字段一致
      （`▶ 请求` / `◆ 思考分片开始` / `◆ 工具调用` / `◆ 工具结果` / `■ 响应` 含 `rawProbe`）
- [ ] 真机跑通三类用例：纯问答、带工具调用、思考流式（用推理模型）

---

### P1 — 第二引擎接入（**条件触发**，仅云 provider）

> 触发条件：§6 的 `P1-A` 通过且 `P1-B`/`P1-C` 验证通过。否则本阶段不启动。

**交付物**

- `lib/core/agent/engine/<sdk>_engine.dart`：实现 `AgentEngine`
- **工具适配器**：遍历 `AgentToolCatalog.enabled` 注册为引擎侧 tool，handler 统一落到 `_executeTool`
  （利用现有协议注册表这一单一来源，**不逐个改 19 个工具**）
- 模型配置映射：`AgentModel` → 引擎 provider（**必须支持自定义 baseUrl**）
- 设置页加"引擎"选择项，**默认 genkit**（保证一键回退）

**验收标准**

- [ ] 同一提示词 + 同一工具集下，两引擎的 `AIAgentResponse` 输出可比
- [ ] 工具调用协议对齐（参数名 / 返回结构一致，工具侧无需分支）
- [ ] reasoning 流式可用；不可用则回退 genkit 并记录原因

---

### P2 — 按需引入原语（仅当有明确收益）

按价值排序，**默认不引**：

1. `PreToolUse` / `PermissionRequestHook` → 对接现有敏感确认（`_isSensitiveTool` + `confirmAction`）
2. `RunState` 序列化 / 恢复 → 对接现有异步任务续接（`_continueAfterAsyncTool`）
3. 其余（Subagents / Snapshots / Sh / Vfs / MCP）→ **不引**

---

## 4. 迁移后收益

- 换引擎 = 新增实现类（而非改动 600–900 行业务代码）；
- SDK 特例收拢：若目标引擎原生支持「自定义 baseUrl + reasoning 流式」，
  可**删除** `openai_reasoning_model.dart`（约 150 行特例）；
- `rawProbe` / `maxTurns` / provider 装配等细节不再出现在业务层。

---

## 5. 风险与对策

| 风险 | 影响 | 对策 |
| --- | --- | --- |
| P0 分层引入行为回归 | 高 | 以 `AIAgentResponse` 日志做改造前后逐字段比对；**分两步提交**：先加接口不动逻辑，再切换调用 |
| 事件抽象盖不住引擎差异（`maxTurns` 语义、工具并行等） | 中 | 抽象**只覆盖事件**，循环控制权留在引擎内部；拿不准的先不抽象 |
| 流式高频事件导致 UI 通知刷屏 | 中 | 沿用现有 `_notifyMessages` 策略，不新增事件通道 |
| 第二引擎不可安装 / 能力不匹配 | 高 | P1 设为条件触发；P0 不受影响 |
| 端侧模型重复建设 | 中 | 明确不采用外部 SDK 的端侧 provider，本地推理继续走 `gstore_mod_llm` |

---

## 6. 前置待确认（阻塞项）

| # | 事项 | 2026-09-14 实测 | 影响 |
| --- | --- | --- | --- |
| **P1-A** | 目标 SDK 是否可安装 | `pub.dev/packages/*` → 404；`pub.dev/api/packages/*` → 404；`pub.dev/api/search` 无此包；GitHub 仓库 → 404。**结论：当前不可安装** | **阻塞 P1** |
| **P1-B** | 是否支持**自定义 baseUrl**（OpenAI 兼容任意端点） | 官方文档仅见云 provider 的 `apiKey` 构造，未见 baseUrl | 若"否"→ 覆盖不了本项目主场景（DeepSeek / OpenRouter / 自建 / 本地端点），**直接否决** |
| **P1-C** | 是否解析 OpenAI 兼容端点的 `reasoning_content`（其事件流含 `ThinkingDelta`） | 未验证 | 若"否"→ reasoning 能力不如现状 |
| **P1-D** | 端侧 provider 是否绑定自带 llama.cpp | 其 `FllamaProvider` 自带 llama.cpp | 与 `gstore_mod_llm` 重复 → **明确不采用其端侧 provider** |

> 备注：外部 SDK 官方站点宣称"加一行 pubspec 即可安装"，与上述实测不符；
> 若其为内测/私有分发，请提供可获取渠道后再评估 P1。

---

## 7. 实施顺序总览

```
P0 引擎抽象 ──► (P1 条件触发：P1-A/B/C 通过) ──► P2 按需原语
   ▲
   └── 不依赖任何外部 SDK，可立即启动；收益独立成立
```

**建议起点**：P0。它不依赖外部 SDK，且能立刻收拢现有特例。

---

## 附录 A：耦合面复现命令

```bash
cd <repo>

# 1) genkit 符号引用计数（按文件）
rg -c 'generateStream<|defineTool<|defineModel\(|ModelResponse|ModelRef|ModelResponseChunk|TextPart|ReasoningPart|ToolRequestPart|ToolResponsePart|GenkitConverter|supportsTools|Genkit\(|googleAI|openAI\.model|Role\.|Message\(' lib/core/agent

# 2) 引用 genkit / chat UI 的文件清单
rg -l 'package:genkit|package:flutter_gen_ai_chat_ui' lib

# 3) 确认工具执行层归属（不属于 genkit）
rg -n '^class AiAction' ~/.pub-cache/hosted/pub.dev/flutter_gen_ai_chat_ui-*/lib
# → .../lib/src/models/ai_action.dart:458
```

## 附录 B：调研结论摘要（外部 SDK）

- 候选 SDK 定位：纯 Dart 移动端 agent SDK，事件流含 `TextDelta` / `ThinkingDelta` / `ToolCalled` / `ToolResult` / `Finished`，
  原语覆盖 Subagents / Skills（渐进披露）/ Snapshots / Hooks / Vfs+Sh / ModelRoute / MCP。
- **与本项目重合度**：Skills 渐进披露、敏感确认、会话落盘我们**已自建**；
  其端侧 provider 与本项目 Rust 模块**重复**；真正多出来的是 `ThinkingDelta`、Subagents、Snapshots fork/revert、MCP、生命周期 Hooks。
- **结论**：在它可安装且支持自定义 baseUrl / reasoning 之前，**不具备替换或并存的前提**；
  先做 P0 抽象，待条件满足再评估 P1。
