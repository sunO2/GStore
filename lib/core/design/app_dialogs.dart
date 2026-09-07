import 'package:flutter/material.dart';
import 'package:flutter/material.dart' as m show showDialog;

import 'package:gstore/core/navigation/nav_key.dart';

import 'app_colors.dart';
import 'app_borders.dart';
import 'app_spacing.dart';
import 'app_radius.dart';
import 'app_typography.dart';
import 'app_components.dart';

/// 统一的弹框组件
///
/// 提供符合 GStore 设计规范的 Dialog、Snackbar、BottomSheet、Alert 组件。
/// 呈现通道：生产（MaterialApp.router）与测试宿主（MaterialApp +
/// appNavigatorKey / scaffoldMessengerKey）均经全局 key 呈现。
class AppDialogs {
  AppDialogs._();

  /// Snackbar 显示通道：挂载到 MaterialApp.router（main.dart）。
  static final GlobalKey<ScaffoldMessengerState> scaffoldMessengerKey =
      GlobalKey();

  // ========== 上下文与主题获取 ==========

  /// 全局 Navigator context（MaterialApp.router 挂载后可用；测试环境为 null）。
  static BuildContext? get _navContext => appNavigatorKey.currentContext;

  static ThemeData get _theme {
    final ctx = _navContext;
    if (ctx != null) return Theme.of(ctx);
    return ThemeData.light();
  }

  static TextTheme get _textTheme => _theme.textTheme;
  static ColorScheme get _colorScheme => _theme.colorScheme;

  /// 主题边框侧边：宽度随主题 borderStyle（cardTheme.shape.side），颜色可覆盖。
  /// 无任何宿主 context 时回退 1.0 宽度，保证不崩。
  static BorderSide _themeBorderSide({Color? color}) {
    final ctx = _navContext;
    if (ctx != null) {
      return AppBorders.sideOf(ctx, color: color);
    }
    return BorderSide(color: color ?? _colorScheme.borderLight, width: 1);
  }

  /// 底部安全区 padding + 键盘 inset（无宿主 context 时为 0）。
  static double _bottomSafePadding() {
    final ctx = _navContext;
    if (ctx != null) {
      final media = MediaQuery.of(ctx);
      return media.padding.bottom + media.viewInsets.bottom;
    }
    return 0;
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
    final ctx = _navContext;
    if (ctx == null) {
      return Future.value(null);
    }
    return m.showDialog<bool>(
      context: ctx,
      builder: (_) => _buildDialog(
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

    // 呈现通道：ScaffoldMessenger（挂载于 MaterialApp，见 main.dart）。
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
                if (title != null && title.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: AppSpacing.xs),
                    child: Text(
                      title,
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
    final ctx = _navContext;
    if (ctx == null) {
      return Future.value(null);
    }
    return showModalBottomSheet<T>(
      context: ctx,
      backgroundColor: Colors.transparent,
      isDismissible: true,
      enableDrag: true,
      isScrollControlled: isScrollControlled,
      builder: (_) => _buildBottomSheet(
        title: title,
        children: children,
        onClose: onClose,
      ),
    );
  }

  /// 关闭底部弹层并返回结果（经 appNavigatorKey 的 Navigator pop）。
  ///
  /// [AppDialogs.showBottomSheet] 的 children 是预构建 widget、拿不到 sheet
  /// 自身的 context，关闭/返回值统一走这里。
  static void popSheet<T>(T? result) {
    final navigator = appNavigatorKey.currentState;
    if (navigator != null) {
      navigator.pop<T?>(result);
    }
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
                final navigator = appNavigatorKey.currentState;
                if (navigator != null) {
                  navigator.pop<T>(item);
                }
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
          SizedBox(height: _bottomSafePadding()),
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

  /// 显示加载对话框（可叠加；navigator 未挂载时静默跳过）。
  static void showLoading({String message = '加载中...'}) {
    final navigator = appNavigatorKey.currentState;
    if (navigator == null) {
      return;
    }
    m.showDialog<void>(
      context: navigator.context,
      barrierDismissible: false,
      builder: (_) => _buildLoadingDialog(message),
    );
  }

  /// 关闭加载对话框（关闭最顶部的对话框）。
  static void dismissLoading() {
    final navigator = appNavigatorKey.currentState;
    if (navigator != null) {
      navigator.pop();
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
