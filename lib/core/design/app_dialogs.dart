import 'package:flutter/material.dart';
import 'package:flutter/material.dart' as m show showDialog;

import 'package:gstore/core/navigation/nav_key.dart';

import 'app_colors.dart';
import 'app_borders.dart';
import 'app_spacing.dart';
import 'app_radius.dart';
import 'app_typography.dart';
import 'app_components.dart';
import 'app_sheet.dart';

/// 统一弹层组件（GStore 设计规范）
///
/// 提供符合 GStore 设计规范的 Snackbar、BottomSheet、确认/提示框与 Loading。
///
/// ## 统一约定（新代码务必遵守）
/// - **确认框 / 提示框 / 选择器 / 表单**：一律走底部弹层（BottomSheet）——
///   即本类的 [showConfirmSheet] / [showAlertSheet] / [showContentSheet] /
///   [showBottomSheet]，其底层统一使用 [AppSheetScaffold]（见 app_sheet.dart）。
///   **禁止**再直接使用 `showDialog` + `AlertDialog` 手写弹框。
/// - **仅 Loading 遮罩**保留居中 Dialog（[showLoading]），因为它不是交互框。
/// - 提示类消息（成功/失败/警告）用 [showSuccess] / [showError] 等 Snackbar。
///
/// 兼容说明：[showDialog] 保留了旧签名（返回 bool?、支持 onConfirm/onCancel），
/// 但呈现方式已改为统一底部弹层，因此既有调用点会自动获得统一风格，无需改动。
/// 新代码建议直接用语义化方法 [showConfirmSheet] / [showAlertSheet]。
///
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

  // ========== 确认 / 提示框（统一底部弹层）==========

  /// 显示确认弹层（危险/普通操作的通用入口）。
  ///
  /// [title] 标题
  /// [message] 文本内容（与 [content] 二选一）
  /// [content] 自定义内容 Widget（内容过长会自动内部滚动）
  /// [confirmText] 确认按钮文字，默认"确定"；传 null 时不显示确认按钮
  /// [cancelText] 取消按钮文字，默认"取消"；传 null 时不显示取消按钮
  /// [onConfirm] / [onCancel] 对应按钮的回调
  /// [isDangerous] 危险操作（确认按钮红色）
  ///
  /// 返回：确认 true / 取消或遮罩关闭 false|null。
  static Future<bool?> showConfirmSheet({
    required String title,
    String? message,
    Widget? content,
    String? confirmText = '确定',
    String? cancelText = '取消',
    VoidCallback? onConfirm,
    VoidCallback? onCancel,
    bool isDangerous = false,
    Widget? icon,
    Color? iconColor,
  }) {
    return showDialog(
      title: title,
      content: content ?? (message ?? ''),
      confirmText: confirmText,
      cancelText: cancelText,
      onConfirm: onConfirm,
      onCancel: onCancel,
      isDangerous: isDangerous,
      icon: icon,
      iconColor: iconColor,
    );
  }

  /// 显示单按钮提示弹层（纯告知，无取消）。
  static Future<void> showAlertSheet({
    required String title,
    String? message,
    Widget? content,
    String confirmText = '知道了',
    Widget? icon,
    Color? iconColor,
  }) async {
    await showDialog(
      title: title,
      content: content ?? (message ?? ''),
      confirmText: confirmText,
      cancelText: null,
      icon: icon,
      iconColor: iconColor,
    );
  }

  /// 显示自定义内容弹层（表单 / 详情 / 列表等）。
  ///
  /// [content] 内容区，超出限高时自动内部滚动；
  /// [actions] 底部固定操作按钮；[scrollable] 内容自带滚动区时传 false。
  static Future<T?> showContentSheet<T>({
    String? title,
    String? subtitle,
    Widget? icon,
    Color? iconColor,
    required Widget content,
    List<Widget> actions = const <Widget>[],
    bool scrollable = true,
    double maxHeightFactor = 0.8,
  }) {
    final ctx = _navContext;
    if (ctx == null) return Future<T?>.value(null);
    return AppSheet.show<T>(
      context: ctx,
      title: title,
      subtitle: subtitle,
      icon: icon,
      iconColor: iconColor,
      content: content,
      actions: actions,
      scrollable: scrollable,
      maxHeightFactor: maxHeightFactor,
      contentPadding: AppSpacing.onlyHorizontalXL,
    );
  }

  /// 显示标准弹层（旧 API，保留签名以兼容既有调用点）。
  ///
  /// 呈现方式已统一为底部弹层（BottomSheet）。新代码建议使用
  /// [showConfirmSheet] / [showAlertSheet] / [showContentSheet]。
  static Future<bool?> showDialog({
    String? title,
    dynamic content,
    String? confirmText = '确定',
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
    return AppSheet.show<bool>(
      context: ctx,
      title: title,
      icon: icon,
      iconColor: iconColor,
      contentPadding: AppSpacing.onlyHorizontalXL,
      content: _buildContent(content),
      actions: [
        if (cancelText != null)
          TextButton(
            onPressed: () {
              popSheet<bool?>(false);
              onCancel?.call();
            },
            child: Text(cancelText),
          ),
        if (confirmText != null)
          FilledButton(
            style: isDangerous
                ? FilledButton.styleFrom(backgroundColor: _colorScheme.error)
                : null,
            onPressed: () {
              popSheet<bool?>(true);
              onConfirm?.call();
            },
            child: Text(confirmText),
          ),
      ],
    );
  }

  /// 内容标准化：Widget 原样使用，其余转文本。
  static Widget _buildContent(dynamic content) {
    if (content is Widget) return content;
    return Text(content.toString(), style: _textTheme.bodyMedium);
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

  /// 显示底部弹层（统一骨架 [AppSheetScaffold]）。
  ///
  /// [title] 弹层标题
  /// [children] 内容组件列表（超出限高自动内部滚动）
  ///
  /// 说明：[isScrollControlled] / [onClose] 仅为兼容旧签名保留。
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
    return AppSheet.show<T>(
      context: ctx,
      title: title,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
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

  /// 显示选择列表底部弹层
  ///
  /// [title] 弹层标题
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

  // ========== Alert（确认框的语义化封装）==========

  /// 显示确认弹层
  static Future<bool?> showConfirmDialog({
    required String title,
    required String message,
    String confirmText = '确定',
    String cancelText = '取消',
    bool isDangerous = false,
  }) {
    return showConfirmSheet(
      title: title,
      message: message,
      confirmText: confirmText,
      cancelText: cancelText,
      isDangerous: isDangerous,
    );
  }

  /// 显示成功提示弹层
  static Future<void> showSuccessDialog({
    String title = '操作成功',
    String? message,
    String confirmText = '确定',
  }) {
    return showAlertSheet(
      title: title,
      message: message ?? '',
      confirmText: confirmText,
      icon: const Icon(Icons.check_circle),
      iconColor: AppColors.success,
    );
  }

  /// 显示错误提示弹层
  static Future<void> showErrorDialog({
    String title = '操作失败',
    String? message,
    String confirmText = '确定',
  }) {
    return showAlertSheet(
      title: title,
      message: message ?? '',
      confirmText: confirmText,
      icon: const Icon(Icons.error),
      iconColor: AppColors.error,
    );
  }

  /// 显示警告确认弹层
  static Future<bool?> showWarningDialog({
    required String title,
    String? message,
    String confirmText = '继续',
    String cancelText = '取消',
  }) {
    return showConfirmSheet(
      title: title,
      message: message ?? '',
      confirmText: confirmText,
      cancelText: cancelText,
      icon: const Icon(Icons.warning),
      iconColor: AppColors.warning,
    );
  }

  /// 显示删除确认弹层
  static Future<bool?> showDeleteDialog({
    String title = '确认删除？',
    String message = '此操作无法撤销，确定要删除吗？',
    String confirmText = '删除',
    String cancelText = '取消',
  }) {
    return showConfirmSheet(
      title: title,
      message: message,
      confirmText: confirmText,
      cancelText: cancelText,
      isDangerous: true,
      icon: const Icon(Icons.delete_outline),
      iconColor: AppColors.error,
    );
  }

  // ========== Loading ==========

  /// 显示加载对话框（可叠加；navigator 未挂载时静默跳过）。
  ///
  /// 注意：Loading 是遮罩而非交互框，保留居中 Dialog 呈现。
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

// ========== 底部弹层选择项组件 ==========

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
