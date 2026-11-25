---
name: installed-apps-management
description: 用户查询已安装应用，或要求卸载、清理数据、清缓存、强制停止应用时使用。
---

# 已安装应用管理

1. 查询：调用 `installedApps`，`action=list`，可按关键词过滤；检查单个应用时使用 `action=check`。
2. 卸载、清理数据、清缓存或强制停止前，必须先调用 `confirmAction` 取得确认。
3. 用户确认后再执行实际操作；Shizuku 未授权时提示用户到设置授权。
4. 反馈操作成功或失败及具体原因，不要静默忽略失败。
