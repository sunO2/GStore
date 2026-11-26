# AI 助手文件工作区计划

## 实施状态

- Phase 1 ✅ 工作区服务、fileList/fileRead/fileApprove/fileWrite、路径沙箱、审批 token、审计
- Phase 2 ✅ 设置开关、文件工作区页面、配额、最近操作、清空
- Phase 3 ✅ SAF 导入/导出、fileMkdir/fileDelete/fileMove/fileEdit、图片预览、二进制元数据

## Phase 4：多工作区（已实现）

- 工作区从单一目录升级为具名工作区：
  - `<app support>/agent_workspaces/<workspaceId>/`
  - 旧 `<app support>/agent_workspace/` 自动迁移到 `default`
- 每个会话通过 `session_workspace:<sessionId>` 绑定工作区
- 新会话默认继承当前工作区
- 工作区页面支持：
  - 查看当前工作区
  - 切换已有工作区
  - 新建工作区
- 切换工作区会清空审批 token，避免跨工作区复用
- 文件工具自动使用当前会话绑定的工作区

## WorkspaceFs 抽象（已实现）

- 新增 `WorkspaceFs` 接口：
  - `resolve/stat/list/read/readBytes/writeBytes/delete/move/mkdir/stats/clear/localPathFor`
- 新增内部后端 `InternalWorkspaceFs`：
  - `dart:io` 真实路径
  - 路径沙箱、符号链接校验
  - 临时文件 + rename 原子写
- `AgentWorkspaceService` 已改为委托 `WorkspaceFs`：
  - 审批、配额、审计、工作区切换逻辑保持不变
  - file* 工具与 UI 不感知底层实现
- 后续接 SAF 时只需新增 `SafWorkspaceFs`，无需改工具层

## SAF 外部工作区（已实现）

- 新增 `SafWorkspaceFs`：
  - `content://` tree URI
  - `ContentResolver` / `DocumentsContract`
  - 目录选择 + `takePersistableUriPermission`
- 新增 Android 通道 `gstore/saf_workspace`：
  - pickDirectory / hasPermission
  - resolve/stat/list/read/readBytes
  - writeBytes/delete/move/mkdir/stats/clear
- 工作区注册表支持：
  - `type: internal | saf`
  - `uri: content://...`
- 工作区页面新增「选择手机目录（SAF）」
- 外部工作区：
  - 跳过应用内 5MB / 200 文件总量配额
  - 仍限制单文件写入 512KB
  - 审批 token 绑定相对路径；切换工作区后失效
  - 图片预览通过 `readBytes` 回退，不依赖真实路径
- 已知限制：
  - SAF 写入不保证原子
  - 跨目录移动依赖 provider 支持
  - `COLUMN_SIZE` 可能为空，统计为尽力而为
  - 目录授权被撤销后需要重新选择

## 目标

让 AI 助手能够读取、写入、创建文件，同时保证：

- 默认关闭
- 只能访问应用内工作区
- 写操作必须经过用户确认
- 路径无法穿越到工作区外
- 有大小、数量、总量限制
- 所有操作可审计

非目标：

- 不开放 `/sdcard`、其他应用目录、数据库、shared_prefs
- 不允许模型静默写入
- 不依赖 `MANAGE_EXTERNAL_STORAGE`

## 威胁模型

- Prompt Injection：网页/文件内容诱导模型读写敏感文件
- 路径穿越：`../`、绝对路径、编码变体
- 符号链接绕过
- 覆盖配置/数据库
- 无限写入填满存储
- 读文件后外发（WebDAV/上传）
- 模型伪造确认

核心原则：

> 安全门禁由服务层执行，不能只依赖提示词或模型自觉。

## Phase 1：工作区 + 读写工具 + 写入门禁

### 工作区

```text
<app support>/agent_workspace/
```

- 应用私有目录，无存储权限
- 相对路径访问
- 单文件写入 ≤ 512KB
- 单次读取 ≤ 256KB
- 工作区总容量 ≤ 5MB
- 最多 200 个文件

### 工具

| 工具 | 作用 |
|---|---|
| `fileList` | 列出工作区目录 |
| `fileRead` | 读取文本文件 |
| `fileApprove` | 请求用户批准写/创建，返回一次性 approvalId |
| `fileWrite` | 使用 approvalId 创建/写入文件 |

### 写入门禁

1. 模型先调用 `fileApprove(action, path, content)`
2. 服务生成确认卡片：操作、路径、大小、内容预览
3. 用户点「允许」→ 生成一次性 approvalId
4. 模型调用 `fileWrite(approvalId, path, content)`
5. 服务校验 approvalId、路径、内容 hash，写入并消费 token
6. 内容不一致 / token 过期 / 未审批 → 拒绝

补充：

- `fileApprove` / `fileWrite` 标记为 alwaysSensitive，后台执行直接拒绝
- approvalId 5 分钟过期、单次使用、最多缓存 16 个
- 写入使用临时文件 + rename，避免半写损坏
- 审计记录独立于工作区（模型不可读写）

### 路径安全

- 拒绝绝对路径
- 拒绝 `..`
- 规范化后必须仍在工作区根目录内
- 拒绝符号链接
- 写文件时解析父目录真实路径
- 读文件时解析文件真实路径

### 设置

- 默认关闭
- 开启后才向模型下发文件工具
- 关闭时执行文件工具直接拒绝

## Phase 2：设置入口 + 工作区页面 + 审计

- AI 助手设置页增加「允许 AI 访问文件」开关
- 增加「文件工作区」页面：
  - 文件列表、大小、修改时间
  - 文本预览
  - 图片预览
  - 清空工作区
  - 使用量 / 配额
  - 最近操作记录
- 审计记录展示：时间、动作、路径、大小、结果

## Phase 3：SAF 导入导出 + 删除/移动/目录 + 二进制

- 工作区页面支持 SAF 导入文件（复制到工作区）
- 工作区页面支持 SAF 导出文件（用户选择保存位置）
- 新增工具：
  - `fileMkdir`
  - `fileDelete`（需 approval）
  - `fileMove`（需 approval）
- 二进制文件：
  - 列表显示类型/大小
  - 文本读取失败时返回元数据
  - 工作区页面可预览常见图片
- 审计与配额覆盖删除/移动/导入

## 验证

- 路径穿越、绝对路径、符号链接
- 大小/数量/总量限制
- approval 过期、内容不一致、重复使用
- 关闭文件访问时工具不可用
- 后台禁止 fileApprove/fileWrite
- 工作区页面展示/清空/导入/导出
- 全量 agent 测试 + release 构建
