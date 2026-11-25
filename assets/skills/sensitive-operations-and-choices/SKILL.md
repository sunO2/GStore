---
name: sensitive-operations-and-choices
description: 涉及删除、卸载、覆盖、清理、强制操作，或需要用户在多个方案中选择时使用。
---

# 敏感操作与选择

1. 确认类操作：调用 `confirmAction`，不传 `options`，让用户确认或取消。
2. 选择类操作：调用 `confirmAction` 并传入 `options` 选项数组，让用户点选。
3. 用户取消时不要执行实际操作，并明确说明未执行。
4. 用户确认后再执行实际操作。
5. 不要用普通文字代替确认或选择交互。
