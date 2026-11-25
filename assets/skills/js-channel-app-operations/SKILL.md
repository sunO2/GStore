---
name: js-channel-app-operations
description: 用户提到 js_ 前缀渠道、自定义脚本渠道，或应用来自脚本渠道时使用。
---

# 脚本渠道应用操作

1. 脚本渠道标识为 `js_` 开头，例如 `js_pingan`，不属于常规渠道枚举。
2. 搜索：调用 `searchApp`，`channel` 直接传脚本渠道 key。
3. 查详情：调用 `getAppInfo`，`channel` 传脚本渠道 key。
4. 下载：调用 `downloadApp`，`channel` 传脚本渠道 key；脚本渠道详情会给出完整下载 URL，直接下载，不要猜测架构。
5. 管理渠道应用：调用 `channelApp`，`channel` 传脚本渠道 key。
6. 检查更新：调用 `updateApps`，`channel` 传脚本渠道 key。
7. 脚本渠道可能需要先配置环境变量，例如账号密码；失败时提示用户到设置中的脚本渠道页面配置。
