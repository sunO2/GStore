# Genkit Agent 能力接入评估

## 背景

GStore 当前 AI 助手基于 Genkit Dart 1.0，但 `AgentService` 保留了自研回合循环：

- `lib/core/agent/agent_service.dart`
  - `chat()`
  - `_runAgentLoop()`
  - `_generateStep()`
  - `_executeToolRequests()`
- `AgentToolCatalog` 负责工具协议和动态工具子集
- Rust `AgentStore` 负责会话、消息、记忆和 Trace 持久化
- UI 依赖 `AgentMessage`、`ValueNotifier` 和自定义确认弹层

官方 `developing-genkit-dart` Skill 已安装到：

```text
.agents/skills/developing-genkit-dart/
```

该 Skill 面向 Genkit Dart 1.0，当前项目 `genkit 1.0.3` 与其目标版本一致。

## 关键结论

官方建议对话式 Agent 优先使用 `ai.defineAgent`，但 GStore 不应直接替换现有循环。

更合适的路径是：

```text
现有 AgentService
  → 抽出可复用的回合执行器
  → 包装为 ai.defineCustomAgent
  → 逐步接入 Session / Interrupt
  → 最后再评估是否使用 defineAgent
```

原因：

- GStore 需要自定义工具筛选、并行调度、MCP 动态注册
- 工具执行需要驱动 UI 消息、下载进度和确认弹层
- 本地小模型存在无工具降级模式
- 会话历史目前由 Rust 持久化，不能直接切到 FileSessionStore
- Genkit Agents/Sessions/Snapshots 仍为 experimental API

## 能力对照

| Genkit 能力 | 对 GStore 的价值 | 当前建议 |
|---|---|---|
| `defineAgent` | 标准多轮会话、工具循环 | 暂不直接替换 |
| `defineCustomAgent` | 保留自定义回合控制，同时获得 Agent 外壳 | 下一阶段优先评估 |
| `toolApproval` / interrupts | 官方人工确认与恢复机制 | 第二阶段评估，保留现有确认作为回退 |
| SessionStore / snapshots | 会话快照、分支、后台任务 | 需要 Rust 适配层，暂缓 |
| `skills()` Middleware | `SKILL.md` 技能加载 | 已接入 |
| `retry()` | 模型瞬态错误重试 | 可作为低风险增强单独评估 |
| Genkit CLI trace | 模型输入输出、工具调用追踪 | 先做开发环境 PoC |
| Schemantic | 类型安全工具/状态 Schema | 新工具可优先采用，历史工具不迁 |

## 分阶段计划

### Phase 1：开发工具链（当前）

- [x] 安装官方 `developing-genkit-dart` Skill
- [x] 阅读 Agents、Custom Agents、Sessions、HITL、Middleware 参考
- [x] 验证 `genkit start:flutter` 能构建、安装并启动 GStore
- [x] 通过 `genkit trace:list` 捕获 GStore AI 回合
- [x] 记录 `genkit start:flutter` 真机调试流程

验收标准：

- 能通过 `genkit trace:list` 找到一次 GStore AI 回合
- 能看到模型请求、工具调用和响应
- 不改变生产运行路径

#### CLI PoC 结果（2026-11-24）

已完成：

- Genkit CLI `1.45.0` 可运行
- `genkit start:flutter --noui` 成功构建并启动 GStore
- 在 Pixel 4 上实际发起 AI 对话
- `genkit trace:list` 成功找到 trace
- `genkit trace:get --format json` 能看到完整 system prompt、模型输出和 token usage

成功 trace：

```text
b6e0b996066d38a3042fe1e437f02160
```

#### 根因

Genkit CLI 给 Flutter 注入的是宿主机的 `127.0.0.1` 地址：

- Telemetry: `http://127.0.0.1:4033`
- Reflection: `ws://127.0.0.1:3200`

但 App 运行在 Android 真机上，手机里的 `127.0.0.1` 指向手机自身，不是开发机。CLI 不会自动为 Android 真机执行 `adb reverse`，因此 AI 回合正常完成，但 trace 无法回传。

#### 正确启动顺序

```bash
# 1. 先反向映射 telemetry 和 reflection 端口
adb reverse tcp:4033 tcp:4033
adb reverse tcp:3200 tcp:3200

# 2. 启动 Genkit + Flutter
/tmp/opencode/genkit-cli-poc/node_modules/.bin/genkit \
  start:flutter --noui --non-interactive -- -d 99161FFAZ00AMH

# 3. 在 App 内发起一次 AI 对话

# 4. 查询 trace（非交互环境必须加 --non-interactive）
genkit --non-interactive trace:list --limit 5
genkit --non-interactive trace:get <traceId> --format json
```

注意：

- Reflection 端口默认从 `3200-3400` 中动态选择；若日志显示的不是 `3200`，
  需要按实际端口补 `adb reverse`。
- `trace:list` / `trace:get` 在非交互终端必须使用全局
  `--non-interactive`，否则会停在 Cookie 确认提示。
- `genkit start` 是长驻进程，不适合 CI；自动验证优先使用 `flow:run`。
- 该流程仅用于开发调试，不改变生产运行路径。

### Phase 2：只读 Shadow Runtime

目标：不替换 `AgentService`，新增一个实验性 `GenkitReadOnlyShadowRuntime`。

- [x] 使用 `defineCustomAgent`
- [x] 复用现有工具目录和工具执行器
- [x] 只开放只读工具：`searchApp`、`getAppInfo`
- [x] 通过编译期 feature flag 启用
- [x] 提供 `AgentService.debugRunReadOnlyShadow()` 手动对比入口
- [x] 提供 `AgentService.debugRunReadOnlyComparison()` 同题双跑入口
- [x] 新增 `Genkit 对比实验` 诊断页
- [x] 单元测试覆盖工具执行与结果回灌
- [x] 组件测试覆盖对比页基础渲染
- [x] 在 Pixel 4 + 真实 OpenAI 兼容模型上完成 3 组只读样本对比

启用方式：

```bash
flutter run \
  --dart-define=GSTORE_GENKIT_READ_ONLY_SHADOW=true \
  -d <device-id>
```

入口：

```dart
final result = await agentService.debugRunReadOnlyShadow('找一个终端工具');
```

代码：

```text
lib/core/agent/genkit_read_only_shadow.dart
test/genkit_read_only_shadow_test.dart
```

设计约束：

- 只读 Runtime 使用独立的 `Genkit` 实例，避免覆盖主 Agent 的工具注册
- 不写入 Rust 会话存储
- 不开放下载、安装、配置修改、确认弹层
- 默认 flag 为 `false`，正常用户路径完全不受影响
- Shadow 失败只返回 `ShadowAgentResult.error`，不影响主 Agent
- 对比页的 “现有 Loop” 是 headless 只读副本，不是直接调用
  `AgentService.chat()`，避免污染当前会话
- 两项按顺序运行，第二次可能命中 Provider 提示缓存，耗时不作为严格基准

诊断页：

```text
Android 设置 → AI 助手 → 模型设置 → Genkit 对比实验
```

仅在 `GSTORE_GENKIT_READ_ONLY_SHADOW=true` 时显示入口。

#### Phase 2 真机样本结果

设备：Pixel 4，Android 13；模型：`hy4-flash-free`（OpenAI 兼容端点）。

| 样本 | 现有 Loop | defineCustomAgent | 结论 |
|---|---|---|---|
| Find an open source screenshot tool | 16.7s / 5 tools / 9307 tokens | 20.9s / 5 tools / 3258 tokens | 工具路径一致；Shadow 更慢但 token 更少 |
| hello | 5.2s / 0 tools / 1514 tokens | 3.2s / 0 tools / 1578 tokens | 无工具场景 Shadow 更快 |
| Show Termux details from F-Droid | 14.3s / 2 tools / 7483 tokens | 12.1s / 2 tools / 3124 tokens | Shadow 更快且 token 更少 |

注意：

- 两项顺序运行，第二次可能命中 Provider prompt cache，因此 token/耗时不构成严格基准。
- 3 组样本中 Shadow 工具选择与最终内容均可用，没有写操作。
- 继续扩大样本时建议增加“Shadow 先运行”顺序，消除缓存顺序偏差。

不涉及：

- 会话持久化迁移
- 确认机制替换
- 下载/安装类写操作

### Phase 3：Interrupt 适配

已直接在正式确认链路上实现，不再保留独立实验分支。

- [x] 模型请求 `confirmAction` 时暂停当前模型回合
- [x] 暂停前不执行同批其他工具，避免确认前发生副作用
- [x] 保存完整工具回合上下文（conversation/model/toolNames/trace）
- [x] 用户确认后继续同一模型回合
- [x] 非确认工具在用户选择后统一执行
- [x] 直接调用 `runTool('confirmAction')` 仍保留阻塞语义
- [x] 保留现有 `_pendingConfirmations` 的持久化确认 UI
- [x] 确认 UI 继续使用现有消息卡/底部弹层，不新增独立分支
- [x] 新增暂停/恢复回归测试

实现要点：

- `_runAgentLoop` 检测到 `confirmAction` 时不调用工具执行器，而是设置
  `_modelConfirmationPause` 并返回。
- `resolveConfirmation` 优先处理模型回合暂停；用户选择后调用
  `_resumeAfterModelConfirmation`。
- 恢复时构造确认工具响应，再继续 `_runAgentLoop`，复用同一 trace 和 turnId。
- 暂停期间 `busy` 保持 true，防止用户在同一确认未处理时发送新消息。
- 应用重启后的确认消息仍可恢复 UI；但当前不恢复内存中的模型回合上下文，
  这是与原有行为一致的边界。

测试：

```text
test/agent_confirm_interrupt_test.dart
```

验证：

- 暂停时不执行工具
- 确认后继续第二轮模型调用
- trace 记录 1 个工具请求和 1 个工具响应
- 直接调用 `runTool` 的旧确认测试保持通过

### Phase 4：Session 适配

两种可选方案：

1. **Client-managed state（推荐先试）**
   - Rust `AgentStore` 继续作为权威存储
   - 每回合把历史注入 Genkit SessionState
   - 不引入第二套会话真相源

2. **Custom SessionStore**
   - 用 Rust `AgentStore` 实现 Genkit `SessionStore`
   - 需要处理 snapshot、分支、原子写入和 JSON 兼容
   - 复杂度较高，暂不优先

### Phase 5：完整 Agent 化

只有在 Phase 2-4 稳定后，才评估：

- 普通 `defineAgent`
- 后台 detached turn
- 多 Agent 委派
- `remoteAgent` / HTTP 服务端模式

## 不建议立即做的事

- 不要用 `defineAgent` 直接替换 `_runAgentLoop`
- 不要把 Rust 会话历史复制到 `FileSessionStore`
- 不要现在删除 `confirmAction` 和自定义确认持久化
- 不要为所有现有工具重写 Schemantic Schema
- 不要引入后台 Agent，除非明确需要服务端长任务

## Genkit CLI PoC 步骤

```bash
# 不全局安装时可直接使用 npx
npx genkit-cli --version

# Flutter 运行（需要已连接设备/模拟器）
npx genkit-cli start:flutter -- -d <device-id>

# 另开终端检查 trace
npx genkit-cli trace:list
npx genkit-cli trace:get <traceId> --format json
```

注意：

- `genkit start` 是长驻进程，不适合 CI
- `flow:run` 只支持 Flow，不支持直接运行 Agent
- GStore 当前没有独立 Flow；需要时用临时 Flow 包装一轮对话
- Flutter 端能否稳定连上 CLI 的 telemetry 通道需要真机验证

## 与现有 Skills 的关系

两类 Skills 不要混淆：

- `.agents/skills/developing-genkit-dart/`
  - 给 AI 编码助手使用
  - 提升 Genkit 代码生成和迁移准确率
- `assets/skills/*/SKILL.md`
  - GStore 运行时 Agent 使用
  - 由 Genkit `skills()` Middleware 加载

两者互不替代。
