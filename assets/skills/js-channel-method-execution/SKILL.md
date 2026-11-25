---
name: js-channel-method-execution
description: 需要调用脚本渠道特有方法，例如读取配置、切换版本环境或执行自定义脚本能力时使用。
---

# 脚本渠道方法执行

1. 调用 `runJsChannel` 执行脚本渠道暴露的方法。
2. 参数包括 `channel`、`method` 和可选的 `params` map。
3. 常见方法包括 `getConfig`、`versionOptions` 和 `switchVersion`。
4. 如果脚本未实现该方法，改用预置工具或告知用户当前能力边界。
5. 先确认渠道是 `js_` 前缀的脚本渠道，再调用本技能中的工具。
