# 核心模块：Agent 助手

> 开发 Wiki 第五篇 · Genkit 集成、工具调用、提示词与技能库

## 1. 模块结构

```
lib/core/agent/
├── agent_service.dart       # 核心服务（Genkit 集成、工具注册、会话管理）
├── agent_model_store.dart   # 模型配置存储（Gemini / OpenAI 兼容）
├── agent_session_store.dart # 会话持久化（多会话、分页）
├── agent_prompt.dart        # 双语言系统提示词构建器（en/zh）
├── agent_skills.dart        # 技能库（10 个技能，中英双语工作流）
├── platform_arch.dart       # 设备架构检测与平台描述
lib/page/agent/              # 聊天 UI（时间轴、确认节点、工具胶囊）
```

## 2. 模型配置（agent_model_store.dart）

| 项 | 说明 |
| --- | --- |
| Provider | `google`（Gemini）、`openai`（OpenAI 及兼容服务） |
| 默认模型 | gemini-2.0-flash / gpt-4o-mini |
| 存储 | SharedPreferences（键 `agent_models` / `agent_selected_model_id`） |
| CRUD | add / update / remove / select / clearAll |

`AgentModel` 提供 `effectiveModel` / `effectiveBaseUrl` / `displayName` 等便捷 getter。

## 3. 会话持久化（agent_session_store.dart）

- `AgentSession`：会话（id / title / createdAt / updatedAt / messages）。
- `SessionMessage`：轻量消息（文本 + 工具记录字段 + seq + turnId）。
- `AgentSessionStore`：多会话管理、历史分页加载。

### 历史分页

- 首次加载 `initialTurnsCount = 5` 个**完整回合**（以用户消息为锚点，避免切分对话）。
- `loadMoreHistory()` 每次补全一组完整对话，返回新增消息供 UI 增量同步。
- 恢复顺序：`time` 为主、`seq` 为辅；重启后 `seq` 计数器推进到历史最大值 + 1，防止顺序错乱。

## 4. 工具注册（agent_service.dart）

AgentService 同时向两套机制注册工具：

1. **Genkit `ai.defineTool`**（云端 LLM 流式调用）。
2. **`AiAction` / `ActionController`**（原生工具执行 + 回调）。

### 工具清单

| 工具名 | 说明 |
| --- | --- |
| `searchApp` | 多渠道搜索应用 |
| `downloadApp` | 下载（GitHub 自动匹配架构；vivo 自动解析 vivoId） |
| `installApp` | 安装 APK |
| `manageApp` | "我的应用"管理（list/add/remove/isAdded） |
| `channelApp` | 渠道应用管理 |
| `getAppInfo` | 应用详情/版本 |
| `updateApps` | 检查更新 |
| `backup` | 备份/恢复（export/import） |
| `manageDownload` | 下载任务管理（list/pause/resume/clean） |
| `themeControl` | 主题控制（mode/toggle/color） |
| `fdroidRepo` | F-Droid 仓库（list/load/search/stats） |
| `webdavSync` | WebDAV 云备份（list/upload/download/status） |
| `installedApps` | 已安装应用（list/check/uninstall/clearData/clearCache/forceStop） |
| `confirmAction` | 用户确认/选择交互（敏感操作必须） |

### 流式输出分步展示

- 聊天采用 Genkit `generateStream` + `flutter_gen_ai_chat_ui`。
- 工具调用时，已输出的文本被"定稿"为独立 agent 消息（`_commitActiveStreamText`），
  后续文本由流式循环懒创建，实现 **"回复 → 工具 → 回复"** 的时间线顺序。
- 停止生成：`_cancelRequested` 置位，同时取消进行中的下载任务。

### 确认交互（confirmAction）

- 敏感/不可逆操作（卸载、清数据、恢复备份、删除会话、移除应用等）**必须**先调用 `confirmAction`。
- 支持多选一：`options` 传选项数组，UI 渲染为可点击按钮。
- `_requestUserConfirmation` 挂起等待，UI 通过 `resolveConfirmation(msgId, choice)` 完成。

## 5. 系统提示词（agent_prompt.dart）

- 双语言：默认英文（专业严谨），`AgentPrompt.useChinese()` 切换。
- 内容：工具清单、敏感操作清单、确认/选择场景、使用规则、**技能知识库**、错误处理指引。
- 动态注入 `platformDescription`（设备 CPU 架构）。

## 6. 技能库（agent_skills.dart）

10 个技能，每个包含触发条件 + 中英双语工作流：

1. App Recommendation（推荐应用）
2. Download & Install Flow（下载安装流程）
3. App Update Check（应用更新检查）
4. Backup & Restore（备份与恢复）
5. Installed Apps Management（已安装应用管理）
6. Sensitive Operations & Choices（敏感操作与选择）
7. Download Management（下载管理）
8. F-Droid Repository（F-Droid 仓库）
9. WebDAV Cloud Backup（WebDAV 云备份）
10. Troubleshooting & Failure Handling（问题诊断与失败处理）

`AgentSkills.renderAll(language:)` 注入系统提示词。

## 7. 聊天 UI（lib/page/agent/）

- **回合时间轴** `_TurnTimeline`：同回合 agent 文本 + 工具调用按执行顺序竖向展示，显示消息时间。
- **工具胶囊**：运行中显示 AppLoading 角标，点击弹详情（可复制）。
- **确认节点**：待确认时高亮问题 + 确认/取消（或多选一）按钮，选择后置灰展示结果。
- 历史分页：reverse 列表滚到视觉顶部触发 `loadMoreHistory`（分页期间禁止自动滚动）。
- 思考中 loading 使用 App 通用 `AppLoading`。

## 8. 相关测试

- `test/agent_skills_test.dart`：技能双语渲染、完整性。
- `test/agent_prompt_test.dart`：提示词构建、语言切换。
- `test/agent_model_store_test.dart`：模型配置与 Store CRUD 持久化。
- `test/agent_session_store_test.dart`：会话序列化、工具字段兼容。
- `test/agent_group_order_test.dart`：时间轴分组顺序。
