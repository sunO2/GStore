---
name: fdroid-repository
description: 用户询问 F-Droid，或要求加载、刷新、搜索 F-Droid 仓库时使用。
---

# F-Droid 仓库

1. 查看仓库列表：调用 `fdroidRepo`，`action=list`。
2. 加载或刷新仓库：调用 `fdroidRepo`，`action=load`，可按需设置 `force`。
3. 搜索 F-Droid 应用：调用 `fdroidRepo`，`action=search`，并提供 `keyword`。
4. 反馈仓库状态、应用数量或搜索结果。
