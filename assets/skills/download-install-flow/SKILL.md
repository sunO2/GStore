---
name: download-install-flow
description: 用户要求下载或安装应用时，先定位目标，再按下载、确认、安装的顺序执行。
---

# 下载安装流程

1. 下载前先调用 `searchApp` 找到目标应用，确认 `appId` 和 `channel`。
2. 调用 `downloadApp` 下载；GitHub 渠道会自动匹配设备 CPU 架构。
3. 下载完成后告知用户保存路径。
4. 询问用户是否安装，用户确认后再调用 `installApp`。
5. 安装成功后提示完成；失败时说明原因，例如网络异常、APK 损坏或权限不足。
6. 下载大文件或执行敏感操作前，先调用 `confirmAction` 取得确认。
