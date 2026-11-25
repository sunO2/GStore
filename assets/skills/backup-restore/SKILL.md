---
name: backup-restore
description: 用户要求备份、恢复、导出或导入 GStore 数据时，安全地执行本地或 WebDAV 备份流程。
---

# 备份与恢复

1. 导出备份：调用 `backup`，`action=export`，可选择是否包含应用配置。备份内容包括已添加应用、渠道库、应用配置、分类标签、代理配置、F-Droid 仓库源和 Agent 模型配置，不包含下载记录。
2. 导入或恢复：调用 `backup`，`action=import`，需要提供 `filePath`。
3. 恢复会覆盖现有数据，必须先调用 `confirmAction` 取得用户确认。
4. 备份完成后告知用户文件保存位置。
5. WebDAV 云备份：先确认网盘已配置；未配置时引导用户到设置。
6. 操作完成后反馈结果；失败时给出存储权限或路径检查建议。
