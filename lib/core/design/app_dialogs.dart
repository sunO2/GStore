import 'package:flutter/material.dart';
import 'package:get/get.dart';

import 'app_colors.dart';
import 'app_borders.dart';
import 'app_spacing.dart';
import 'app_radius.dart';
import 'app_animations.dart';
import 'app_typography.dart';
import 'app_components.dart';

/// 统一的弹框组件
///
/// 提供符合 GStore 设计规范的 Dialog、Snackbar、BottomSheet、Alert 组件
/// 使用 GetX 实现路由和动画
class AppDialogs {
  AppDialogs._();

  /// Snackbar 显示通道：挂载到 GetMaterialApp（main.dart），
  /// 替代 GetX overlay snackbar（Get.snackbar 与新版 Flutter overlay 兼容问题
  /// 导致真机提示静默不显示）。
  static final GlobalKey<ScaffoldMessengerState> scaffoldMessengerKey =
      GlobalKey();

  // ========== 主题获取 ==========

  static ThemeData get _theme {
    try {
      return Get.theme;
    } catch (_) {
      // GetX 未初始化（测试环境/启动早期无 GetMaterialApp 上下文）
      // → 降级默认亮色主题，保证不崩（仅影响视觉 token，不影响逻辑）
      return ThemeData.light();
    }
  }

  static TextTheme get _textTheme => _theme.textTheme;
  static ColorScheme get _colorScheme => _theme.colorScheme;

  /// 主题边框侧边：宽度随主题 borderStyle（cardTheme.shape.side），颜色可覆盖。
  /// GetX 未初始化（测试环境/启动早期）时回退 1.0 宽度，保证不崩。
  static BorderSide _themeBorderSide({Color? color}) {
    final context = Get.context;
    if (context != null) {
      return AppBorders.sideOf(context, color: color);
    }
    return BorderSide(color: color ?? _colorScheme.borderLight, width: 1);
  }

  // ========== Dialog ==========

  /// 显示标准对话框
  ///
  /// [title] 对话框标题
  /// [content] 对话框内容（可以是 Widget 或 String）
  /// [confirmText] 确认按钮文字，默认"确定"
  /// [cancelText] 取消按钮文字，默认"取消"，为 null 时不显示取消按钮
  /// [onConfirm] 确认回调
  /// [onCancel] 取消回调
  /// [isDangerous] 是否为危险操作（确认按钮使用红色）
  static Future<bool?> showDialog({
    String? title,
    dynamic content,
    String confirmText = '确定',
    String? cancelText,
    VoidCallback? onConfirm,
    VoidCallback? onCancel,
    bool isDangerous = false,
    Widget? icon,
    Color? iconColor,
  }) {
    return Get.dialog<bool>(
      _buildDialog(
        title: title,
        content: content,
        confirmText: confirmText,
        cancelText: cancelText,
        onConfirm: onConfirm,
        onCancel: onCancel,
        isDangerous: isDangerous,
        icon: icon,
        iconColor: iconColor,
      ),
      barrierDismissible: true,
    );
  }

  /// 构建对话框
  static Widget _buildDialog({
    String? title,
    dynamic content,
    String? confirmText,
    String? cancelText,
    VoidCallback? onConfirm,
    VoidCallback? onCancel,
    bool isDangerous = false,
    Widget? icon,
    Color? iconColor,
  }) {
    final contentWidget = content is Widget
        ? content
        : Text(
            content.toString(),
            style: _textTheme.bodyMedium,
            textAlign: TextAlign.center,
          );

    return Dialog(
      elevation: 0,
      backgroundColor: _colorScheme.dialogSurface,
      shape: RoundedRectangleBorder(
        borderRadius: AppRadius.allXL,
        side: _themeBorderSide(color: _colorScheme.borderLight),
      ),
      insetPadding: AppSpacing.onlyHorizontalLG,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: Padding(
          padding: AppSpacing.allXL,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 图标（可选）
              if (icon != null) ...[
                IconTheme(
                  data: IconThemeData(
                    color: iconColor ?? _colorScheme.primary,
                    size: 48,
                  ),
                  child: icon,
                ),
                const SizedBox(height: AppSpacing.lg),
              ],

              // 标题
              if (title != null) ...[
                Text(
                  title,
                  style: _textTheme.titleLarge?.copyWith(
                    fontWeight: AppTypography.weightSemiBold,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: AppSpacing.md),
              ],

              // 内容
              contentWidget,
              const SizedBox(height: AppSpacing.xxl),

              // 操作按钮
              // 使用 Builder 获取 dialog 自身的 context，用 Navigator.pop 确定性关闭
              // （避免 Get.back 依赖全局 navigator 状态导致偶发不关闭）
              Builder(
                builder: (dialogContext) => Row(
                  mainAxisAlignment: cancelText == null
                      ? MainAxisAlignment.center
                      : MainAxisAlignment.end,
                  children: [
                    if (cancelText != null)
                      TextButton(
                        onPressed: () {
                          Navigator.of(dialogContext).pop(false);
                          onCancel?.call();
                        },
                        child: Text(cancelText),
                      ),
                    if (cancelText != null)
                      const SizedBox(width: AppSpacing.sm),
                    if (confirmText != null)
                      FilledButton(
                        style: isDangerous
                            ? FilledButton.styleFrom(
                                backgroundColor: _colorScheme.error,
                              )
                            : null,
                        onPressed: () {
                          Navigator.of(dialogContext).pop(true);
                          onConfirm?.call();
                        },
                        child: Text(confirmText),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ========== Snackbar ==========

  /// 显示成功提示
  static void showSuccess(
    String message, {
    String? title,
    Duration duration = const Duration(seconds: 3),
  }) {
    _showSnackbar(
      title: title ?? '成功',
      message: message,
      type: _SnackbarType.success,
      duration: duration,
    );
  }

  /// 显示错误提示
  static void showError(
    String message, {
    String? title,
    Duration duration = const Duration(seconds: 4),
  }) {
    _showSnackbar(
      title: title ?? '错误',
      message: message,
      type: _SnackbarType.error,
      duration: duration,
    );
  }

  /// 显示警告提示
  static void showWarning(
    String message, {
    String? title,
    Duration duration = const Duration(seconds: 3),
  }) {
    _showSnackbar(
      title: title ?? '警告',
      message: message,
      type: _SnackbarType.warning,
      duration: duration,
    );
  }

  /// 显示信息提示
  static void showInfo(
    String message, {
    String? title,
    Duration duration = const Duration(seconds: 3),
  }) {
    _showSnackbar(
      title: title ?? '提示',
      message: message,
      type: _SnackbarType.info,
      duration: duration,
    );
  }

  /// 显示普通提示
  static void showSnackbar(
    String message, {
    String? title,
    Duration duration = const Duration(seconds: 3),
  }) {
    _showSnackbar(
      title: title,
      message: message,
      type: _SnackbarType.normal,
      duration: duration,
    );
  }

  /// Snackbar 类型
  static void _showSnackbar({
    required String? title,
    required String message,
    required _SnackbarType type,
    required Duration duration,
  }) {
    final IconData? icon;
    final Color indicatorColor;

    switch (type) {
      case _SnackbarType.success:
        icon = Icons.check_circle;
        indicatorColor = _colorScheme.primary;
        break;
      case _SnackbarType.error:
        icon = Icons.error;
        indicatorColor = _colorScheme.error;
        break;
      case _SnackbarType.warning:
        icon = Icons.warning;
        indicatorColor = AppColors.warning;
        break;
      case _SnackbarType.info:
        icon = Icons.info;
        indicatorColor = _colorScheme.primary;
        break;
      case _SnackbarType.normal:
        icon = null;
        indicatorColor = Colors.transparent;
        break;
    }

    // 优先 ScaffoldMessenger（挂载于 GetMaterialApp，见 main.dart）：
    // 根治 Get.snackbar（GetX overlay）与新版 Flutter overlay 兼容问题导致的真机静默不显示。
    final messenger = scaffoldMessengerKey.currentState;
    if (messenger != null) {
      messenger
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (title != null && title!.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: AppSpacing.xs),
                    child: Text(
                      title!,
                      style: _textTheme.titleSmall?.copyWith(
                        fontWeight: AppTypography.weightMedium,
                      ),
                    ),
                  ),
                Row(
                  children: [
                    if (icon != null) ...[
                      Icon(icon, size: 20, color: indicatorColor),
                      const SizedBox(width: AppSpacing.sm),
                    ],
                    Expanded(
                      child: Text(message, style: _textTheme.bodySmall),
                    ),
                  ],
                ),
              ],
            ),
            backgroundColor: _colorScheme.surface,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: AppRadius.allMD),
            margin: AppSpacing.allLG,
            duration: duration,
          ),
        );
      return;
    }

    // fallback：key 未挂载（启动早期）时退回 GetX overlay snackbar。
    // 必须先同步检查 overlay 是否可用：Get.snackbar 的异常在异步队列
    // （SnackbarController._configureOverlay）中抛出，try/catch 无法捕获；
    // 测试环境（无 GetMaterialApp）overlayContext 为 null → 静默跳过，保证不崩。
    if (Get.overlayContext != null) {
      try {
        Get.snackbar(
          title ?? '',
          message,
          backgroundColor: _colorScheme.surface,
          borderRadius: AppRadius.md,
          boxShadows: const [],
          margin: AppSpacing.allLG,
          padding: AppSpacing.allMD,
          snackPosition: SnackPosition.BOTTOM,
          duration: duration,
          animationDuration: AppAnimations.normal,
          forwardAnimationCurve: Curves.easeOutCubic,
          reverseAnimationCurve: Curves.easeInCubic,
          barBlur: 0,
          snackStyle: SnackStyle.GROUNDED,
          colorText: _colorScheme.onSurface,
          leftBarIndicatorColor: indicatorColor,
          titleText: title != null
              ? Text(
                  title,
                  style: _textTheme.titleSmall?.copyWith(
                    fontWeight: AppTypography.weightMedium,
                  ),
                )
              : const SizedBox.shrink(),
          messageText: Row(
            children: [
              if (icon != null) ...[
                Icon(icon, size: 20, color: indicatorColor),
                const SizedBox(width: AppSpacing.sm),
              ],
              Expanded(
                child: Text(
                  message,
                  style: _textTheme.bodySmall,
                ),
              ),
            ],
          ),
          icon: icon != null
              ? Icon(icon, color: indicatorColor, size: 24)
              : null,
        );
      } catch (_) {
        // 同步阶段的兜底（Get.snackbar 内部异步异常无法捕获，见上）
      }
    }
  }

  // ========== BottomSheet ==========

  /// 显示底部弹窗
  ///
  /// [title] 弹窗标题
  /// [children] 内容组件列表
  /// [isScrollControlled] 是否可滚动，默认 true
  /// [onClose] 关闭回调
  static Future<T?> showBottomSheet<T>({
    String? title,
    required List<Widget> children,
    bool isScrollControlled = true,
    VoidCallback? onClose,
  }) {
    return Get.bottomSheet<T>(
      _buildBottomSheet(
        title: title,
        children: children,
        onClose: onClose,
      ),
      backgroundColor: Colors.transparent,
      isDismissible: true,
      enableDrag: true,
      isScrollControlled: isScrollControlled,
    );
  }

  /// 显示选择列表底部弹窗
  ///
  /// [title] 弹窗标题
  /// [items] 选择项列表
  /// [selectedItem] 当前选中的项
  /// [onItemSelected] 选中回调
  static Future<T?> showSelectionBottomSheet<T>({
    String? title,
    required List<T> items,
    required T? selectedItem,
    required String Function(T item) itemLabel,
  }) {
    return showBottomSheet<T>(
      title: title,
      children: items
          .map(
            (item) => _SelectionItem(
              label: itemLabel(item),
              isSelected: item == selectedItem,
              onTap: () {
                Get.back(result: item);
              },
            ),
          )
          .toList(),
    );
  }

  /// 构建底部弹窗
  static Widget _buildBottomSheet({
    String? title,
    required List<Widget> children,
    VoidCallback? onClose,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: _colorScheme.surface,
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(AppRadius.xxl),
          topRight: Radius.circular(AppRadius.xxl),
        ),
        border: Border(
          top: _themeBorderSide(color: _colorScheme.borderLight),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 拖拽指示器
          Container(
            margin: AppSpacing.onlyVerticalMD,
            width: 32,
            height: 4,
            decoration: BoxDecoration(
              color: _colorScheme.outlineVariant,
              borderRadius: AppRadius.allXS,
            ),
          ),

          // 标题
          if (title != null) ...[
            Padding(
              padding: AppSpacing.onlyHorizontalLG,
              child: Text(
                title,
                style: _textTheme.titleLarge?.copyWith(
                  fontWeight: AppTypography.weightSemiBold,
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
          ],

          // 内容
          ...children,

          // 底部安全区域
          SizedBox(height: Get.mediaQuery.padding.bottom),
        ],
      ),
    );
  }

  // ========== Alert（确认对话框）==========

  /// 显示确认对话框
  ///
  /// [title] 对话框标题
  /// [message] 对话框内容
  /// [confirmText] 确认按钮文字
  /// [cancelText] 取消按钮文字
  /// [isDangerous] 是否为危险操作
  static Future<bool?> showConfirmDialog({
    required String title,
    required String message,
    String confirmText = '确定',
    String cancelText = '取消',
    bool isDangerous = false,
  }) {
    return showDialog(
      title: title,
      content: message,
      confirmText: confirmText,
      cancelText: cancelText,
      isDangerous: isDangerous,
    );
  }

  /// 显示成功确认对话框
  static Future<void> showSuccessDialog({
    String title = '操作成功',
    String? message,
    String confirmText = '确定',
  }) {
    return showDialog(
      title: title,
      content: message ?? '',
      confirmText: confirmText,
      cancelText: null,
      icon: const Icon(Icons.check_circle),
      iconColor: AppColors.success,
    );
  }

  /// 显示错误确认对话框
  static Future<void> showErrorDialog({
    String title = '操作失败',
    String? message,
    String confirmText = '确定',
  }) {
    return showDialog(
      title: title,
      content: message ?? '',
      confirmText: confirmText,
      cancelText: null,
      icon: const Icon(Icons.error),
      iconColor: AppColors.error,
    );
  }

  /// 显示警告确认对话框
  static Future<bool?> showWarningDialog({
    required String title,
    String? message,
    String confirmText = '继续',
    String cancelText = '取消',
  }) {
    return showDialog(
      title: title,
      content: message ?? '',
      confirmText: confirmText,
      cancelText: cancelText,
      icon: const Icon(Icons.warning),
      iconColor: AppColors.warning,
    );
  }

  /// 显示删除确认对话框
  static Future<bool?> showDeleteDialog({
    String title = '确认删除？',
    String message = '此操作无法撤销，确定要删除吗？',
    String confirmText = '删除',
    String cancelText = '取消',
  }) {
    return showDialog(
      title: title,
      content: message,
      confirmText: confirmText,
      cancelText: cancelText,
      isDangerous: true,
      icon: const Icon(Icons.delete_outline),
      iconColor: AppColors.error,
    );
  }

  // ========== Loading ==========

  /// 显示加载对话框
  static void showLoading({String message = '加载中...'}) {
    Get.dialog(
      _buildLoadingDialog(message),
      barrierDismissible: false,
    );
  }

  /// 关闭加载对话框
  static void dismissLoading() {
    if (Get.isDialogOpen == true) {
      Get.back();
    }
  }

  /// 构建加载对话框
  static Widget _buildLoadingDialog(String message) {
    return Dialog(
      elevation: 0,
      backgroundColor: _colorScheme.dialogSurface,
      shape: RoundedRectangleBorder(
        borderRadius: AppRadius.allXL,
        side: _themeBorderSide(color: _colorScheme.borderLight),
      ),
      child: Padding(
        padding: AppSpacing.allXXL,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const AppLoading(size: AppLoadingSize.medium),
            const SizedBox(height: AppSpacing.lg),
            Text(
              message,
              style: _textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}

// ========== Snackbar 类型枚举 ==========

enum _SnackbarType {
  success,
  error,
  warning,
  info,
  normal,
}

// ========== 底部弹窗选择项组件 ==========

class _SelectionItem extends StatelessWidget {
  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  const _SelectionItem({
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return InkWell(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.md),
        decoration: BoxDecoration(
          border: Border(
            top: AppDialogs._themeBorderSide(
              color: theme.colorScheme.borderLight,
            ),
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: isSelected
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurface,
                  fontWeight:
                      isSelected ? AppTypography.weightMedium : AppTypography.weightRegular,
                ),
              ),
            ),
            if (isSelected)
              Icon(
                Icons.check,
                color: theme.colorScheme.primary,
                size: 20,
              ),
          ],
        ),
      ),
    );
  }
}

// ========== 便捷扩展方法 ==========

/// AppDialogs 便捷扩展
extension AppDialogsExtensions on GetInterface {
  /// 显示成功提示
  void showSuccess(String message) => AppDialogs.showSuccess(message);

  /// 显示错误提示
  void showError(String message) => AppDialogs.showError(message);

  /// 显示警告提示
  void showWarning(String message) => AppDialogs.showWarning(message);

  /// 显示信息提示
  void showInfo(String message) => AppDialogs.showInfo(message);
}
