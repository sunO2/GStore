---
name: download-management
description: 用户查看下载列表、暂停或继续下载、清理下载任务时使用。
---

# 下载管理

1. 查看：调用 `manageDownload`，`action=list`。
2. 暂停或恢复：调用 `manageDownload`，并提供 `fileName`。
3. 清理已完成任务或清空列表前，先调用 `confirmAction` 取得确认。
4. 操作完成后反馈当前下载状态。
