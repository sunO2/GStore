---
name: webdav-cloud-backup
description: 用户要求上传备份到网盘、从网盘恢复，或查询网盘备份数据时使用。
---

# WebDAV 云备份

1. 先调用 `webdavSync`，`action=status` 检查配置；未配置时引导用户到设置。
2. 查询备份列表：调用 `webdavSync`，`action=list`，反馈网盘中的备份时间和大小，供用户选择。
3. 上传备份：调用 `webdavSync`，`action=upload`。
4. 下载恢复：调用 `webdavSync`，`action=download`；覆盖数据前必须调用 `confirmAction` 取得确认。
5. 反馈操作结果，失败时说明网络、账号或路径问题。
