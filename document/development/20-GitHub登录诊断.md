# GitHub 登录状态自检（401 排查）

> 入口：**我的 → 已登录用户卡片 → 盾牌图标（检查登录状态）**。
> 代码：`lib/core/service/github_login_check.dart`、`lib/page/home/tab/mine/widgets/github_login_check_sheet.dart`。

## 1. 背景

GitHub 渠道（Rust core）与 Dart 侧 API 共用同一个 Token，但存在两条链路：

| 链路 | 使用位置 | Token 来源 |
|---|---|---|
| Dart API | `DioClient` → `api.github.com` | 内存头 `Authorization: Bearer …` + 本地存储 |
| Rust 渠道 | `github_releases.rs` | `setGithubToken` 写入的 `core_config.github_token` |

任意一侧缺失/陈旧都会表现为 401，仅看 UI 很难判断是哪一侧。

## 2. 检查内容

面板基于统一骨架 `AppSheetScaffold`（`lib/core/design/progress_log_sheet.dart`）：
统一背景/圆角/拖拽条、固定标题与操作区，**底部系统导航区域由骨架背景覆盖**
（不再出现透明条）。备份的 `BackupProgressSheet` 同样改为该骨架（皮肤层），
`showModalBottomSheet` 也统一换成 `AppSheet.showCustom`。

逐行日志（与 WebDAV/备份面板同一套 `ProgressLogSheet`）：

1. 本地 Token：是否存在、长度、**掩码**（`ghp_abc…6789`）、类型（classic PAT / fine-grained / OAuth）；
2. `DioClient` 全局授权头：未设置 / 一致 / **与本地 Token 不一致**（旧 Token 残留）；
3. `GET https://api.github.com/user`：HTTP 状态、`x-oauth-scopes`、
   `x-ratelimit-limit/remaining/reset`、用户 login/id/type/公开仓库数；
4. Rust 通道实测：`ChannelManager.searchApps('termux', from: github, forceRefresh: true)`
   —— 直接命中"渠道 401"的真实路径；
5. 结论 + 建议（重新登录 / 检查代理 / 等待限流重置）。

401/403/网络错误都会以红色日志输出并让面板进入"失败"态（可重试）。

## 3. 修复的隐患

`DioClient.authorization` 的 setter 原先只处理非空值：

```dart
set authorization(String? a) {
  if (a?.isNotEmpty ?? false) _dio.options.headers['Authorization'] = 'Bearer $a';
}
```

退出登录时传入 `null` **不会移除旧头** → 进程内后续请求继续携带已删除的 Token → 401。
现在 setter 在空值时 `remove('Authorization')`，并新增只读 `authorizationHeader` 供自检使用。

## 4. 测试

`test/github_login_check_test.dart`（Dio 桩适配器，不触网）：

- 200：掩码 Token / 头一致 / scopes / 速率限制 / 用户信息 / Rust 正常 / 结论正常；
- 401：红色建议 + 抛异常（面板失败态）+ Rust 侧 401 归因；
- 无 Token：不发起请求直接失败；
- 头与 Token 不一致：告警；
- 403 限流：提示稍后重试；
- `DioClient` 设置/清除授权头（防旧 Token 残留回归）。
