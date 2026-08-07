# GStore 项目开发规则

## 主题 / 设计系统（务必遵守）

GStore 使用 Material 3 + 主题令牌，**禁止硬编码颜色/字号**。详见 `theme-usage-guide.md`。

### 核心规则

1. **颜色/文字**：一律 `Theme.of(context).colorScheme` / `Theme.of(context).textTheme`，禁止 `Colors.blue`、`AppColors.textSecondary` 等硬编码。
2. **确认框/提示框**：一律用 `AppDialogs.showDialog`（`lib/core/design/app_dialogs.dart`），**禁止** `Get.defaultDialog`、手写 `AlertDialog` 做确认框。
   - 危险操作加 `isDangerous: true`（确认按钮红色）。
   - 需要返回值时 `await AppDialogs.showDialog(...)`（返回 `bool?`）。
3. **loading**：用 `AppLoading` / `AppLoadingSize`，不直接用 `CircularProgressIndicator`。
4. **AliIcon（COLR 彩色字体图标）**：必须用 `ColoredAliIcon` 染色，直接 `Icon(AliIcon.xxx)` 在夜间模式会黑色看不清。
5. **Snackbar**：用 `AppDialogs.showSuccess` / `showError` 等统一入口。

## 工具链

- 版本号 `pubspec.yaml`（当前 1.0.24+1），用户未要求不改版本。
- 日志：用 `debugPrint`（main.dart 已重定向到日志查看器），不用 `log()`。
- 验证：改完跑 `dart analyze lib/`、`flutter test`、`flutter build apk --release --target-platform android-arm64`。
- git push 用 SSH：`git@github.com:sunO2/GStore.git`。
