---
name: app-config-management
description: 用户要求查看或修改 GStore 配置、下载更新策略、主题或代理设置时使用。
---

# 应用配置管理

1. 先调用 `configManager`，`action=list`，获取结构化 JSON 快照，包含键、类型、当前值、默认值、枚举值、示例和分组；敏感项已脱敏。
2. 查看单个配置：调用 `configManager`，`action=get`，并提供 `key`。
3. 根据快照中的类型、枚举值和示例构造正确类型的值，调用 `configManager`，`action=set`，提供 `key` 和 `value`。修改后相关功能会自动生效。
4. 清除配置：调用 `configManager`，`action=clear`，并提供 `key`。
5. 反馈结构化结果；失败时说明未知键、类型错误或不允许修改等原因，并重新列出可用配置项。
