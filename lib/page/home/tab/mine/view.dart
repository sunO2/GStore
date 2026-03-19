import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:gstore/http/github/user_info/user_info.dart';
import 'package:gstore/page/web/browser.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'package:gstore/core/core.dart';
import 'package:gstore/core/design/design_tokens.dart';
import 'package:gstore/core/theme/app_theme_config.dart';
import 'package:gstore/page/auth/state.dart';
import '../../logic.dart';

class MinePage extends StatefulWidget {
  const MinePage({super.key});

  @override
  State<MinePage> createState() => _MinePageState();
}

class _MinePageState extends State<MinePage> {
  /// 外观卡片展开状态
  bool _appearanceExpanded = false;

  /// 从主题获取卡片的形状（包含圆角和边框）
  ShapeBorder get _cardShape {
    final theme = Theme.of(context);
    final cardTheme = theme.cardTheme;
    // 如果主题有定义卡片形状，使用它；否则使用默认的
    return cardTheme.shape ??
        RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.lg),
          side: BorderSide(
            color: theme.colorScheme.outlineVariant.withOpacity(0.5),
            width: 1,
          ),
        );
  }

  /// 从主题获取圆角半径（用于小元素）
  double get _smallRadius {
    final shape = Theme.of(context).cardTheme.shape;
    if (shape is RoundedRectangleBorder) {
      // 从卡片的圆角按比例缩小
      final radius = shape.borderRadius;
      if (radius is BorderRadius) {
        // 取左上角的圆角作为基准，然后缩小到约 50%
        final topLeft = radius.topLeft;
        if (topLeft is Radius) {
          return topLeft.x * 0.5;
        }
      }
    }
    return AppRadius.sm; // 默认值
  }

  /// 从主题获取边框样式
  BorderSide get _borderSide {
    final shape = Theme.of(context).cardTheme.shape;
    if (shape is RoundedRectangleBorder) {
      return shape.side;
    }
    return BorderSide(
      color: Theme.of(context).colorScheme.outlineVariant.withOpacity(0.5),
      width: 1,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('我的'),
      ),
      body: SingleChildScrollView(
        padding: AppSpacing.allLG,
        child: Obx(() {
          final user = Get.find<UserManager>().userInfo.value;

          // 判断是否已登录
          final isLoggedIn = user.avatarUrl?.isNotEmpty ?? false;

          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 根据登录状态显示不同的顶部卡片
              if (isLoggedIn)
                _buildUserInfoCard(context, user)
              else
                _buildLoginCard(context),

              const SizedBox(height: AppSpacing.md),

              // 外观卡片（始终显示）
              _buildAppearanceCard(context),

              const SizedBox(height: AppSpacing.md),

              // 快捷功能卡片（始终显示）
              _buildQuickActionsCard(context),
            ],
          );
        }),
      ),
    );
  }

  /// 构建登录卡片（未登录状态）- 小卡片
  Widget _buildLoginCard(BuildContext context) {
    return Card(
      elevation: 0,
      shape: _cardShape,
      child: ListTile(
        contentPadding: AppSpacing.horizontalLG_verticalMD,
        leading: Container(
          width: AppSpacing.xxl + AppSpacing.xl,
          height: AppSpacing.xxl + AppSpacing.xl,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.primaryContainer,
            shape: BoxShape.circle,
          ),
          child: const Icon(
            Icons.code,
            color: AppColors.githubBrand,
            size: AppTypography.iconLG,
          ),
        ),
        title: const Text('未登录'),
        subtitle: const Text('登录 GitHub 以访问更多功能'),
        trailing: FilledButton.tonalIcon(
          onPressed: () {
            Get.toNamed(AppRoute.auth);
          },
          icon: const Icon(Icons.login, size: AppTypography.iconSM),
          label: const Text('登录'),
        ),
      ),
    );
  }

  /// 删除了 _buildReasonItem 方法，不再需要

  /// 构建用户信息卡片（已登录状态）- 只返回用户信息卡片
  Widget _buildUserInfoCard(BuildContext context, UserInfo user) {
    return Card(
      elevation: 0,
      shape: _cardShape,
      child: ListTile(
        contentPadding: AppSpacing.horizontalLG_verticalMD,
        leading: GestureDetector(
          onTap: () {
            if (user.htmlUrl != null) {
              GStoreInAppBrowser inAppBrowser = GStoreInAppBrowser();
              final settings = ChromeSafariBrowserSettings(
                shareState: CustomTabsShareState.SHARE_STATE_ON,
                barCollapsingEnabled: true,
              );
              inAppBrowser.open(
                url: WebUri(user.htmlUrl!),
                settings: settings,
              );
            }
          },
          child: Hero(
            tag: user.avatarUrl ?? '',
            child: ClipOval(
              child: CachedNetworkImage(
                width: AppSpacing.xxl + AppSpacing.xl,
                height: AppSpacing.xxl + AppSpacing.xl,
                fit: BoxFit.cover,
                placeholder: (context, url) => Container(
                  width: AppSpacing.xxl + AppSpacing.xl,
                  height: AppSpacing.xxl + AppSpacing.xl,
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primaryContainer,
                    shape: BoxShape.circle,
                  ),
                  child: const CupertinoActivityIndicator(
                    radius: AppSpacing.sm,
                  ),
                ),
                errorWidget: (context, url, error) => Container(
                  width: AppSpacing.xxl + AppSpacing.xl,
                  height: AppSpacing.xxl + AppSpacing.xl,
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primaryContainer,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.person, size: AppTypography.iconLG),
                ),
                imageUrl: user.avatarUrl ?? '',
              ),
            ),
          ),
        ),
        title: Text(
          user.name ?? user.login ?? '未知用户',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: AppTypography.weightSemiBold,
              ),
        ),
        subtitle: Text(
          '@${user.login ?? ""}',
          style: AppTypography.labelSmall.copyWith(
            color: AppColors.textSecondary,
          ),
        ),
        trailing: IconButton(
          icon: const Icon(Icons.logout, size: AppTypography.iconSM),
          tooltip: '退出登录',
          onPressed: () {
            Get.find<UserManager>().logout();
            AppDialogs.showSuccess(
              '您已成功退出 GitHub 账号',
              title: '已退出登录',
            );
          },
        ),
      ),
    );
  }

  /// 构建快捷功能卡片（始终显示）
  Widget _buildQuickActionsCard(BuildContext context) {
    return Card(
      elevation: 0,
      shape: _cardShape,
      child: Column(
        children: [
          ListTile(
            leading: const Icon(Icons.settings, size: AppTypography.iconMD),
            title: const Text('设置'),
            trailing: const Icon(Icons.chevron_right, size: AppTypography.iconSM),
            onTap: () => Get.toNamed(AppRoute.settings),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.bug_report_outlined, size: AppTypography.iconMD),
            title: const Text('查看日志'),
            trailing: const Icon(Icons.chevron_right, size: AppTypography.iconSM),
            onTap: () => Get.toNamed(AppRoute.logViewer),
          ),
        ],
      ),
    );
  }

  /// 构建外观卡片
  Widget _buildAppearanceCard(BuildContext context) {
    final themeController = Get.find<ThemeController>();

    return Card(
      elevation: 0,
      shape: _cardShape,
      child: Padding(
        padding: AppSpacing.allLG,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 标题栏（带展开/收起按钮）
            Row(
              children: [
                Icon(
                  Icons.palette_outlined,
                  size: AppTypography.iconMD,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: AppSpacing.md),
                Text(
                  '外观',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: AppTypography.weightSemiBold,
                      ),
                ),
                const Spacer(),
                InkWell(
                  onTap: () {
                    setState(() => _appearanceExpanded = !_appearanceExpanded);
                  },
                  borderRadius: BorderRadius.circular(20),
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: AnimatedRotation(
                      turns: _appearanceExpanded ? 0.5 : 0,
                      duration: const Duration(milliseconds: 300),
                      curve: Curves.easeInOut,
                      child: Icon(
                        Icons.expand_more,
                        size: AppTypography.iconMD,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.lg),

            // 主题模式设置
            Obx(() {
              final currentMode = themeController.themeMode;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '主题模式',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: AppColors.textSecondary,
                        ),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  AppSegmentedButton<AppThemeMode>(
                    value: currentMode,
                    segments: const [
                      AppSegment(
                        value: AppThemeMode.system,
                        label: '系统',
                        icon: Icons.brightness_auto,
                      ),
                      AppSegment(
                        value: AppThemeMode.light,
                        label: '浅色',
                        icon: Icons.light_mode,
                      ),
                      AppSegment(
                        value: AppThemeMode.dark,
                        label: '深色',
                        icon: Icons.dark_mode,
                      ),
                    ],
                    onChanged: (AppThemeMode newMode) {
                      themeController.setThemeMode(newMode);
                    },
                  ),
                ],
              );
            }),

            // 展开的详细设置
            AnimatedSize(
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeInOut,
              child: _appearanceExpanded
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(height: AppSpacing.lg),
                        Divider(color: Theme.of(context).colorScheme.outlineVariant.withOpacity(0.3)),
                        const SizedBox(height: AppSpacing.lg),

                        // 颜色设置
                        _buildColorSetting(context, themeController),
                        const SizedBox(height: AppSpacing.lg),

                        // 字体风格
                        _buildFontStyleSetting(context, themeController),
                        const SizedBox(height: AppSpacing.lg),

                        // 圆角风格
                        _buildRadiusStyleSetting(context, themeController),
                        const SizedBox(height: AppSpacing.lg),

                        // 边框风格
                        _buildBorderStyleSetting(context, themeController),
                      ],
                    )
                  : const SizedBox.shrink(),
            ),
          ],
        ),
      ),
    );
  }

  /// 构建颜色设置
  Widget _buildColorSetting(BuildContext context, ThemeController controller) {
    return Obx(() {
      final config = controller.themeConfig;
      final useCustom = config.useCustomColors;
      final currentPrimaryColor = config.primaryColor;

      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '颜色设置',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: AppColors.textSecondary,
                    ),
              ),
              const Spacer(),
              Switch(
                value: useCustom,
                onChanged: (value) {
                  controller.toggleCustomColors();
                },
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ],
          ),
          if (useCustom) ...[
            const SizedBox(height: AppSpacing.md),
            // 颜色预设选择器
            Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              children: [
                _ColorPresetButton(
                  color: const Color(0xFF1976D2),
                  isSelected: currentPrimaryColor == const Color(0xFF1976D2),
                  onTap: () => _setPrimaryColor(context, controller, const Color(0xFF1976D2)),
                ),
                _ColorPresetButton(
                  color: const Color(0xFF388E3C),
                  isSelected: currentPrimaryColor == const Color(0xFF388E3C),
                  onTap: () => _setPrimaryColor(context, controller, const Color(0xFF388E3C)),
                ),
                _ColorPresetButton(
                  color: const Color(0xFFD32F2F),
                  isSelected: currentPrimaryColor == const Color(0xFFD32F2F),
                  onTap: () => _setPrimaryColor(context, controller, const Color(0xFFD32F2F)),
                ),
                _ColorPresetButton(
                  color: const Color(0xFFF57C00),
                  isSelected: currentPrimaryColor == const Color(0xFFF57C00),
                  onTap: () => _setPrimaryColor(context, controller, const Color(0xFFF57C00)),
                ),
                _ColorPresetButton(
                  color: const Color(0xFF7B1FA2),
                  isSelected: currentPrimaryColor == const Color(0xFF7B1FA2),
                  onTap: () => _setPrimaryColor(context, controller, const Color(0xFF7B1FA2)),
                ),
                _ColorPresetButton(
                  color: const Color(0xFF0097A7),
                  isSelected: currentPrimaryColor == const Color(0xFF0097A7),
                  onTap: () => _setPrimaryColor(context, controller, const Color(0xFF0097A7)),
                ),
              ],
            ),
          ],
        ],
      );
    });
  }

  /// 构建字体风格设置
  Widget _buildFontStyleSetting(BuildContext context, ThemeController controller) {
    return Obx(() {
      final currentStyle = controller.themeConfig.fontStyle;

      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '字体风格',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: AppColors.textSecondary,
                ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: AppSpacing.sm,
            children: AppFontStyle.values.map((style) {
              final isSelected = currentStyle == style;
              return FilterChip(
                label: Text(_getFontStyleName(style)),
                selected: isSelected,
                onSelected: (selected) {
                  if (selected) {
                    controller.setFontStyle(style);
                  }
                },
                backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                selectedColor: Theme.of(context).colorScheme.primaryContainer,
                checkmarkColor: Theme.of(context).colorScheme.onPrimaryContainer,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(_smallRadius),
                  side: _borderSide,
                ),
              );
            }).toList(),
          ),
        ],
      );
    });
  }

  /// 构建圆角风格设置
  Widget _buildRadiusStyleSetting(BuildContext context, ThemeController controller) {
    return Obx(() {
      final currentStyle = controller.themeConfig.radiusStyle;

      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '圆角风格',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: AppColors.textSecondary,
                ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: AppSpacing.sm,
            children: AppRadiusStyle.values.map((style) {
              final isSelected = currentStyle == style;
              return FilterChip(
                label: Text(_getRadiusStyleName(style)),
                selected: isSelected,
                onSelected: (selected) {
                  if (selected) {
                    controller.setRadiusStyle(style);
                  }
                },
                backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                selectedColor: Theme.of(context).colorScheme.primaryContainer,
                checkmarkColor: Theme.of(context).colorScheme.onPrimaryContainer,
                avatar: Container(
                  width: 16,
                  height: 16,
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primary,
                    borderRadius: BorderRadius.circular(_getRadiusPreview(style)),
                  ),
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(_smallRadius),
                  side: _borderSide,
                ),
              );
            }).toList(),
          ),
        ],
      );
    });
  }

  /// 构建边框风格设置
  Widget _buildBorderStyleSetting(BuildContext context, ThemeController controller) {
    return Obx(() {
      final currentStyle = controller.themeConfig.borderStyle;

      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '边框风格',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: AppColors.textSecondary,
                ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: AppSpacing.sm,
            children: AppBorderStyle.values.map((style) {
              final isSelected = currentStyle == style;
              return FilterChip(
                label: Text(_getBorderStyleName(style)),
                selected: isSelected,
                onSelected: (selected) {
                  if (selected) {
                    controller.setBorderStyle(style);
                  }
                },
                backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                selectedColor: Theme.of(context).colorScheme.primaryContainer,
                checkmarkColor: Theme.of(context).colorScheme.onPrimaryContainer,
                avatar: Container(
                  width: 16,
                  height: 16,
                  decoration: BoxDecoration(
                    color: Colors.transparent,
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(
                      color: Theme.of(context).colorScheme.outline,
                      width: _getBorderWidth(style),
                    ),
                  ),
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(_smallRadius),
                  side: _borderSide,
                ),
              );
            }).toList(),
          ),
        ],
      );
    });
  }

  /// 设置主色
  void _setPrimaryColor(BuildContext context, ThemeController controller, Color color) {
    controller.setCustomColorTheme(primaryColor: color);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('已设置主题颜色'),
        duration: Duration(milliseconds: AppAnimations.fast.inMilliseconds),
      ),
    );
  }

  /// 获取字体风格名称
  String _getFontStyleName(AppFontStyle style) {
    switch (style) {
      case AppFontStyle.default_:
        return '默认';
      case AppFontStyle.compact:
        return '紧凑';
      case AppFontStyle.standard:
        return '标准';
      case AppFontStyle.spacious:
        return '宽松';
      case AppFontStyle.large:
        return '大号';
    }
  }

  /// 获取圆角风格名称
  String _getRadiusStyleName(AppRadiusStyle style) {
    switch (style) {
      case AppRadiusStyle.default_:
        return '默认';
      case AppRadiusStyle.square:
        return '方形';
      case AppRadiusStyle.slight:
        return '轻微';
      case AppRadiusStyle.standard:
        return '标准';
      case AppRadiusStyle.rounded:
        return '圆润';
      case AppRadiusStyle.circular:
        return '圆形';
    }
  }

  /// 获取圆角预览值
  double _getRadiusPreview(AppRadiusStyle style) {
    switch (style) {
      case AppRadiusStyle.default_:
      case AppRadiusStyle.standard:
        return 4;
      case AppRadiusStyle.square:
        return 0;
      case AppRadiusStyle.slight:
        return 2;
      case AppRadiusStyle.rounded:
        return 6;
      case AppRadiusStyle.circular:
        return 8;
    }
  }

  /// 获取边框风格名称
  String _getBorderStyleName(AppBorderStyle style) {
    switch (style) {
      case AppBorderStyle.default_:
        return '默认';
      case AppBorderStyle.none:
        return '无边框';
      case AppBorderStyle.light:
        return '轻细';
      case AppBorderStyle.standard:
        return '标准';
      case AppBorderStyle.bold:
        return '粗犷';
    }
  }

  /// 获取边框宽度
  double _getBorderWidth(AppBorderStyle style) {
    switch (style) {
      case AppBorderStyle.default_:
      case AppBorderStyle.standard:
        return 1.0;
      case AppBorderStyle.none:
        return 0.0;
      case AppBorderStyle.light:
        return 0.5;
      case AppBorderStyle.bold:
        return 1.5;
    }
  }
}

/// 颜色预设按钮
class _ColorPresetButton extends StatelessWidget {
  final Color color;
  final bool isSelected;
  final VoidCallback onTap;

  const _ColorPresetButton({
    required this.color,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    // 从主题获取圆角半径
    final shape = Theme.of(context).cardTheme.shape;
    double smallRadius = AppRadius.sm;
    BorderSide? themeBorder;
    if (shape is RoundedRectangleBorder) {
      final radius = shape.borderRadius;
      if (radius is BorderRadius) {
        final topLeft = radius.topLeft;
        if (topLeft is Radius) {
          smallRadius = topLeft.x * 0.5;
        }
      }
      themeBorder = shape.side;
    }

    final borderSide = themeBorder ??
        BorderSide(
          color: Theme.of(context).colorScheme.outlineVariant.withOpacity(0.5),
          width: 1,
        );

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(smallRadius),
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(smallRadius),
          border: Border.all(
            color: isSelected
                ? color.withOpacity(0.3) // 使用选中颜色的淡化版本
                : borderSide.color,
            width: isSelected ? 3 : borderSide.width,
          ),
        ),
        child: isSelected
            ? Icon(
                Icons.check,
                color: color.computeLuminance() > 0.5 ? Colors.black : Colors.white,
                size: 20,
              )
            : null,
      ),
    );
  }
}
