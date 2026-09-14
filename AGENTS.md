# GStore 项目开发规则

## 主题 / 设计系统（务必遵守）

GStore 使用 Material 3 + 主题令牌，**禁止硬编码颜色/字号**。详见 `theme-usage-guide.md`。

### 核心规则

1. **颜色/文字**：一律 `Theme.of(context).colorScheme` / `Theme.of(context).textTheme`，禁止 `Colors.blue`、`AppColors.textSecondary` 等硬编码。
2. **弹层（确认框/提示框/选择器/表单）**：一律使用统一底部弹层（BottomSheet）。
   - 语义化入口：`lib/core/design/app_dialogs.dart`（`showConfirmSheet` / `showAlertSheet` / `showContentSheet`）；统一骨架：`lib/core/design/app_sheet.dart`（`AppSheet.show` / `AppSheetScaffold`）。
   - **禁止** `Get.defaultDialog`、`showDialog` + 手写 `AlertDialog`、手写 `showModalBottomSheet`。
   - 确认/危险操作 `showConfirmSheet(isDangerous: true)`（确认按钮红色，返回 `bool?`）；纯提示 `showAlertSheet`；自定义内容/表单 `showContentSheet` 或 `AppSheet.show`（需要自身 context 关闭时用 `AppSheet.showCustom`）。
   - 内容过长时骨架已自动「限高（默认屏高 80%）+ 内容区内部滚动」，**不要**再自己包 `SizedBox`/`SingleChildScrollView`。
   - 兼容：旧的 `AppDialogs.showDialog(...)` 保留签名，呈现已统一为底部弹层。Loading 遮罩仍为居中 Dialog（`AppDialogs.showLoading`）。
3. **loading**：用 `AppLoading` / `AppLoadingSize`，不直接用 `CircularProgressIndicator`。
4. **AliIcon（COLR 彩色字体图标）**：必须用 `ColoredAliIcon` 染色，直接 `Icon(AliIcon.xxx)` 在夜间模式会黑色看不清。
5. **Snackbar**：用 `AppDialogs.showSuccess` / `showError` 等统一入口。

## 工具链

- 版本号 `pubspec.yaml`（当前 1.0.24+1），用户未要求不改版本。
- 日志：用 `debugPrint`（main.dart 已重定向到日志查看器），不用 `log()`。
- 验证：改完跑 `dart analyze lib/`、`flutter test`、`flutter build apk --release --target-platform android-arm64`。
- git push 用 SSH：`git@github.com:sunO2/GStore.git`。
