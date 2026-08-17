import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/theme/theme_controller.dart';
import 'package:gstore/core/theme/app_theme_config.dart';

/// Theme settings page with live preview
class ThemeSettingsPage extends StatefulWidget {
  const ThemeSettingsPage({super.key});

  @override
  State<ThemeSettingsPage> createState() => _ThemeSettingsPageState();
}

class _ThemeSettingsPageState extends State<ThemeSettingsPage> {
  /// theme 模块是否在线（随模块上下线实时更新；下线时整页未启用占位）
  bool _moduleOnline = false;

  /// theme 模块上下线事件订阅（dispose 取消，防泄漏）
  StreamSubscription<ModuleEvent>? _moduleSub;

  @override
  void initState() {
    super.initState();
    _moduleOnline = ModuleManager.instance.isModuleEnabled('theme');
    _moduleSub = ModuleManager.instance.watchModule('theme').listen((_) {
      if (!mounted) return;
      setState(() {
        _moduleOnline = ModuleManager.instance.isModuleEnabled('theme');
      });
    });
  }

  @override
  void dispose() {
    _moduleSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('主题设置'),
      ),
      // theme 模块下线 → 整页未启用占位（不渲染 Obx 功能内容，避免 Get.find 异常）
      body: _moduleOnline ? _buildBody(context) : _buildModuleOffline(context),
    );
  }

  /// theme 模块下线占位
  Widget _buildModuleOffline(BuildContext context) {
    return Center(
      child: Padding(
        padding: AppSpacing.allXL,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.palette_outlined,
              size: AppTypography.iconXXXL,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: AppSpacing.lg),
            Text(
              '主题模块未启用',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: AppSpacing.md),
            Text(
              '请在「模块管理」中启用主题模块',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    return ListView(
        children: [
          // Info banner
          Container(
            margin: AppSpacing.allLG,
            padding: AppSpacing.allMD,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primaryContainer.withOpacity(0.5),
              borderRadius: AppRadius.allMD,
            ),
            child: Row(
              children: [
                Icon(
                  Icons.info_outline,
                  color: Theme.of(context).colorScheme.primary,
                  size: AppTypography.iconLG,
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Text(
                    '点击下方选项即可立即切换主题，可在预览区域查看效果',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ),

          // Theme mode selector
          _buildSectionHeader('主题模式'),
          _buildThemeModeSelector(context),
          const SizedBox(height: AppSpacing.xxl),

          // Color customization
          _buildSectionHeader('颜色设置'),
          _buildColorSettings(context),
          const SizedBox(height: AppSpacing.xxl),

          // Font style
          _buildSectionHeader('字体风格'),
          _buildFontStyleSelector(context),
          const SizedBox(height: AppSpacing.xxl),

          // Radius style
          _buildSectionHeader('圆角风格'),
          _buildRadiusStyleSelector(context),
          const SizedBox(height: AppSpacing.xxl),

          // Border style
          _buildSectionHeader('边框风格'),
          _buildBorderStyleSelector(context),
          const SizedBox(height: AppSpacing.xxl),

          // Preview section
          _buildSectionHeader('预览'),
          _buildPreviewSection(context),
        ],
      );
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: AppSpacing.onlyHorizontalLG,
      child: Text(
        title,
        style: TextStyle(
          fontSize: AppTypography.sizeSM,
          fontWeight: AppTypography.weightMedium,
          color: Colors.grey,
        ),
      ),
    );
  }

  Widget _buildThemeModeSelector(BuildContext context) {
    return Card(
      margin: AppSpacing.allLG,
      child: Obx(() {
        final controller = Get.find<ThemeController>();
        return Column(
          children: AppThemeMode.values.map((mode) {
            final isSelected = controller.themeMode == mode;
            return Column(
              children: [
                if (mode != AppThemeMode.system) const Divider(height: 1),
                ListTile(
                  leading: Icon(_getIconForMode(mode)),
                  title: Text(mode.displayName),
                  trailing: isSelected
                      ? Icon(
                          Icons.check,
                          color: Theme.of(context).colorScheme.primary,
                        )
                      : null,
                  onTap: () async {
                    await controller.setThemeMode(mode);
                    // 显示简短的反馈
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('已切换到${mode.displayName}'),
                          duration: AppAnimations.snackBar,
                        ),
                      );
                    }
                  },
                ),
              ],
            );
          }).toList(),
        );
      }),
    );
  }

  Widget _buildColorSettings(BuildContext context) {
    return Card(
      margin: AppSpacing.allLG,
      child: Obx(() {
        final controller = Get.find<ThemeController>();
        final config = controller.themeConfig;
        final useCustom = config.useCustomColors;

        return Column(
          children: [
            // Toggle custom colors
            SwitchListTile(
              title: const Text('自定义颜色'),
              subtitle: Text(useCustom ? '使用自定义颜色' : '使用壁纸动态色'),
              value: useCustom,
              onChanged: (value) async {
                await controller.toggleCustomColors();
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(value ? '已启用自定义颜色' : '已恢复动态色'),
                      duration: AppAnimations.snackBar,
                    ),
                  );
                }
              },
            ),

            // Custom color options
            if (useCustom) ...[
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.palette),
                title: const Text('主色'),
                subtitle: Text(config.primaryColor != null
                    ? '#${config.primaryColor!.value.toRadixString(16).substring(2).toUpperCase()}'
                    : '未设置'),
                trailing: Container(
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    color: config.primaryColor ?? Theme.of(context).colorScheme.primary,
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: Colors.grey.withOpacity(0.3)),
                  ),
                ),
                onTap: () => _showColorPicker(
                  context,
                  '主色',
                  config.primaryColor ?? Theme.of(context).colorScheme.primary,
                  (color) => controller.setCustomColorTheme(
                    primaryColor: color,
                    secondaryColor: config.secondaryColor,
                    tertiaryColor: config.tertiaryColor,
                  ),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.palette_outlined),
                title: const Text('次要色'),
                subtitle: Text(config.secondaryColor != null
                    ? '#${config.secondaryColor!.value.toRadixString(16).substring(2).toUpperCase()}'
                    : '自动生成'),
                trailing: Container(
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    color: config.secondaryColor ?? Colors.grey,
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: Colors.grey.withOpacity(0.3)),
                  ),
                ),
                onTap: () => _showColorPicker(
                  context,
                  '次要色',
                  config.secondaryColor ?? Colors.grey,
                  (color) => controller.setCustomColorTheme(
                    primaryColor: config.primaryColor ?? Theme.of(context).colorScheme.primary,
                    secondaryColor: color,
                    tertiaryColor: config.tertiaryColor,
                  ),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.brush),
                title: const Text('第三色'),
                subtitle: Text(config.tertiaryColor != null
                    ? '#${config.tertiaryColor!.value.toRadixString(16).substring(2).toUpperCase()}'
                    : '自动生成'),
                trailing: Container(
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    color: config.tertiaryColor ?? Colors.grey,
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: Colors.grey.withOpacity(0.3)),
                  ),
                ),
                onTap: () => _showColorPicker(
                  context,
                  '第三色',
                  config.tertiaryColor ?? Colors.grey,
                  (color) => controller.setCustomColorTheme(
                    primaryColor: config.primaryColor ?? Theme.of(context).colorScheme.primary,
                    secondaryColor: config.secondaryColor,
                    tertiaryColor: color,
                  ),
                ),
              ),
            ],

            // Reset button
            if (useCustom) ...[
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.restore),
                title: const Text('恢复默认'),
                subtitle: const Text('恢复为壁纸动态色'),
                onTap: () async {
                  await controller.resetToDefault();
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('已恢复为默认主题'),
                        duration: AppAnimations.snackBar,
                      ),
                    );
                  }
                },
              ),
            ],
          ],
        );
      }),
    );
  }

  Widget _buildFontStyleSelector(BuildContext context) {
    return Card(
      margin: AppSpacing.allLG,
      child: Obx(() {
        final controller = Get.find<ThemeController>();
        final currentStyle = controller.themeConfig.fontStyle;

        return Column(
          children: AppFontStyle.values.map((style) {
            final isSelected = currentStyle == style;
            final styleName = _getFontStyleName(style);
            return Column(
              children: [
                if (style != AppFontStyle.default_) const Divider(height: 1),
                ListTile(
                  title: Text(styleName,
                      style: TextStyle(
                        fontSize: _getFontScale(style) * 14,
                      )),
                  subtitle: Text(_getFontStyleDescription(style)),
                  trailing: isSelected
                      ? Icon(
                          Icons.check,
                          color: Theme.of(context).colorScheme.primary,
                        )
                      : null,
                  onTap: () async {
                    await controller.setFontStyle(style);
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('已设置为$styleName'),
                          duration: AppAnimations.snackBar,
                        ),
                      );
                    }
                  },
                ),
              ],
            );
          }).toList(),
        );
      }),
    );
  }

  Widget _buildRadiusStyleSelector(BuildContext context) {
    return Card(
      margin: AppSpacing.allLG,
      child: Obx(() {
        final controller = Get.find<ThemeController>();
        final currentStyle = controller.themeConfig.radiusStyle;

        return Column(
          children: AppRadiusStyle.values.map((style) {
            final isSelected = currentStyle == style;
            final styleName = _getRadiusStyleName(style);
            return Column(
              children: [
                if (style != AppRadiusStyle.default_) const Divider(height: 1),
                ListTile(
                  title: Text(styleName),
                  subtitle: Text(_getRadiusStyleDescription(style)),
                  leading: Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(_getRadiusPreview(style)),
                      border: Border.all(
                        color: Theme.of(context).colorScheme.outline.withOpacity(0.5),
                      ),
                    ),
                  ),
                  trailing: isSelected
                      ? Icon(
                          Icons.check,
                          color: Theme.of(context).colorScheme.primary,
                        )
                      : null,
                  onTap: () async {
                    await controller.setRadiusStyle(style);
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('已设置为$styleName'),
                          duration: AppAnimations.snackBar,
                        ),
                      );
                    }
                  },
                ),
              ],
            );
          }).toList(),
        );
      }),
    );
  }

  Widget _buildBorderStyleSelector(BuildContext context) {
    return Card(
      margin: AppSpacing.allLG,
      child: Obx(() {
        final controller = Get.find<ThemeController>();
        final currentStyle = controller.themeConfig.borderStyle;

        return Column(
          children: AppBorderStyle.values.map((style) {
            final isSelected = currentStyle == style;
            final styleName = _getBorderStyleName(style);
            return Column(
              children: [
                if (style != AppBorderStyle.default_) const Divider(height: 1),
                ListTile(
                  title: Text(styleName),
                  subtitle: Text(_getBorderStyleDescription(style)),
                  leading: Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surface,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: Theme.of(context).colorScheme.outline,
                        width: _getBorderWidth(style),
                      ),
                    ),
                  ),
                  trailing: isSelected
                      ? Icon(
                          Icons.check,
                          color: Theme.of(context).colorScheme.primary,
                        )
                      : null,
                  onTap: () async {
                    await controller.setBorderStyle(style);
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('已设置为$styleName'),
                          duration: AppAnimations.snackBar,
                        ),
                      );
                    }
                  },
                ),
              ],
            );
          }).toList(),
        );
      }),
    );
  }

  void _showColorPicker(
    BuildContext context,
    String title,
    Color currentColor,
    ValueChanged<Color> onColorSelected,
  ) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('选择$title'),
        content: SingleChildScrollView(
          child: ColorPicker(
            color: currentColor,
            onColorChanged: onColorSelected,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  IconData _getIconForMode(AppThemeMode mode) {
    switch (mode) {
      case AppThemeMode.system:
        return Icons.brightness_auto;
      case AppThemeMode.light:
        return Icons.light_mode;
      case AppThemeMode.dark:
        return Icons.dark_mode;
    }
  }

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

  String _getFontStyleDescription(AppFontStyle style) {
    switch (style) {
      case AppFontStyle.default_:
        return '使用设计令牌默认设置';
      case AppFontStyle.compact:
        return '小字号，紧凑行高 (90%)';
      case AppFontStyle.standard:
        return '标准字号和行高 (100%)';
      case AppFontStyle.spacious:
        return '大字号，宽松行高 (110%)';
      case AppFontStyle.large:
        return '更大字号，适合无障碍 (120%)';
    }
  }

  double _getFontScale(AppFontStyle style) {
    switch (style) {
      case AppFontStyle.default_:
      case AppFontStyle.standard:
        return 1.0;
      case AppFontStyle.compact:
        return 0.9;
      case AppFontStyle.spacious:
        return 1.1;
      case AppFontStyle.large:
        return 1.2;
    }
  }

  String _getRadiusStyleName(AppRadiusStyle style) {
    switch (style) {
      case AppRadiusStyle.default_:
        return '默认';
      case AppRadiusStyle.square:
        return '方形';
      case AppRadiusStyle.slight:
        return '轻微圆角';
      case AppRadiusStyle.standard:
        return '标准圆角';
      case AppRadiusStyle.rounded:
        return '圆润';
      case AppRadiusStyle.circular:
        return '圆形';
    }
  }

  String _getRadiusStyleDescription(AppRadiusStyle style) {
    switch (style) {
      case AppRadiusStyle.default_:
        return '使用设计令牌默认设置';
      case AppRadiusStyle.square:
        return '无圆角 (0%)';
      case AppRadiusStyle.slight:
        return '小圆角 (50%)';
      case AppRadiusStyle.standard:
        return '标准圆角 (100%)';
      case AppRadiusStyle.rounded:
        return '大圆角 (150%)';
      case AppRadiusStyle.circular:
        return '最大圆角 (200%)';
    }
  }

  double _getRadiusPreview(AppRadiusStyle style) {
    switch (style) {
      case AppRadiusStyle.default_:
      case AppRadiusStyle.standard:
        return 8;
      case AppRadiusStyle.square:
        return 0;
      case AppRadiusStyle.slight:
        return 4;
      case AppRadiusStyle.rounded:
        return 12;
      case AppRadiusStyle.circular:
        return 16;
    }
  }

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

  String _getBorderStyleDescription(AppBorderStyle style) {
    switch (style) {
      case AppBorderStyle.default_:
        return '使用设计令牌默认设置';
      case AppBorderStyle.none:
        return '无边框';
      case AppBorderStyle.light:
        return '细边框，低透明度 (0.5px, 30%)';
      case AppBorderStyle.standard:
        return '标准边框 (1px, 50%)';
      case AppBorderStyle.bold:
        return '粗边框，高透明度 (1.5px, 70%)';
    }
  }

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

  Widget _buildPreviewSection(BuildContext context) {
    return Card(
      margin: AppSpacing.allLG,
      child: Padding(
        padding: AppSpacing.allLG,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Sample card
            Card(
              child: Padding(
                padding: AppSpacing.allMD,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '示例卡片',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: AppTypography.weightSemiBold,
                          ),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    Text(
                      '这是一个示例卡片，用于预览当前主题的效果。',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.md),

            // Sample buttons
            Row(
              children: [
                Expanded(
                  child: ElevatedButton(
                    onPressed: () {},
                    child: const Text('主要按钮'),
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: OutlinedButton(
                    onPressed: () {},
                    child: const Text('次要按钮'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),

            // Sample navigation bar
            Container(
              decoration: BoxDecoration(
                color: Theme.of(context)
                    .colorScheme
                    .primary
                    .withAlpha(AppColors.withAlphaLower),
                borderRadius: AppRadius.allMD,
              ),
              padding: AppSpacing.allMD,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _buildNavItem(
                    context,
                    icon: Icons.home,
                    label: '首页',
                    isSelected: true,
                  ),
                  _buildNavItem(
                    context,
                    icon: Icons.explore_outlined,
                    label: '发现',
                    isSelected: false,
                  ),
                  _buildNavItem(
                    context,
                    icon: Icons.person_outline,
                    label: '我的',
                    isSelected: false,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNavItem(
    BuildContext context, {
    required IconData icon,
    required String label,
    required bool isSelected,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          icon,
          size: AppTypography.iconLG,
          color: isSelected ? colorScheme.primary : colorScheme.onSurface,
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          label,
          style: TextStyle(
            fontSize: AppTypography.sizeXS,
            color: isSelected ? colorScheme.primary : colorScheme.onSurface,
            fontWeight: isSelected
                ? AppTypography.weightSemiBold
                : AppTypography.weightRegular,
          ),
        ),
      ],
    );
  }
}

/// Simple color picker widget
class ColorPicker extends StatefulWidget {
  final Color color;
  final ValueChanged<Color> onColorChanged;

  const ColorPicker({
    super.key,
    required this.color,
    required this.onColorChanged,
  });

  @override
  State<ColorPicker> createState() => _ColorPickerState();
}

class _ColorPickerState extends State<ColorPicker> {
  late Color _selectedColor;

  // Predefined colors
  static const List<Color> _presetColors = [
    Color(0xFF1976D2), // Blue
    Color(0xFF388E3C), // Green
    Color(0xFFD32F2F), // Red
    Color(0xFFF57C00), // Orange
    Color(0xFF7B1FA2), // Purple
    Color(0xFF0097A7), // Cyan
    Color(0xFFC2185B), // Pink
    Color(0xFF5D4037), // Brown
    Color(0xFF455A64), // Blue Grey
    Color(0xFF212121), // Black
  ];

  @override
  void initState() {
    super.initState();
    _selectedColor = widget.color;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Preset colors grid
        GridView.builder(
          shrinkWrap: true,
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 5,
            crossAxisSpacing: 8,
            mainAxisSpacing: 8,
          ),
          itemCount: _presetColors.length,
          itemBuilder: (context, index) {
            final color = _presetColors[index];
            final isSelected = _selectedColor.value == color.value;
            return GestureDetector(
              onTap: () {
                setState(() => _selectedColor = color);
                widget.onColorChanged(color);
              },
              child: Container(
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: isSelected ? Colors.white : Colors.grey.withOpacity(0.3),
                    width: isSelected ? 3 : 1,
                  ),
                ),
                child: isSelected
                    ? const Icon(Icons.check, color: Colors.white)
                    : null,
              ),
            );
          },
        ),
        const SizedBox(height: 16),
        // Current color preview
        Container(
          height: 50,
          decoration: BoxDecoration(
            color: _selectedColor,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.grey.withOpacity(0.3)),
          ),
          child: Center(
            child: Text(
              '#${_selectedColor.value.toRadixString(16).substring(2).toUpperCase()}',
              style: TextStyle(
                color: _selectedColor.computeLuminance() > 0.5
                    ? Colors.black
                    : Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
