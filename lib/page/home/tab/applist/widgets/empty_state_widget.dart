import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:gstore/core/core.dart';
import '../../../logic.dart';

class EmptyStateWidget extends StatelessWidget {
  final VoidCallback onImportSample;

  const EmptyStateWidget({
    super.key,
    required this.onImportSample,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: AppSpacing.allXXL,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.apps_outlined,
              size: AppTypography.iconXXXL,
              color: AppColors.grey400,
            ),
            const SizedBox(height: AppSpacing.lg),
            Text(
              '还没有添加任何应用',
              style: AppTypography.titleMedium.copyWith(
                    color: AppColors.textSecondary,
                  ),
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              '3种方式快速添加应用：',
              style: AppTypography.bodyMedium.copyWith(
                    color: AppColors.textSecondary,
                    fontWeight: AppTypography.weightMedium,
                  ),
            ),
            const SizedBox(height: AppSpacing.lg),
            _buildQuickAddOption(
              context,
              icon: Icons.search,
              title: '快速搜索',
              description: '点击上方搜索栏直接搜索',
              onTap: () => _showQuickSearchGuide(context),
            ),
            const SizedBox(height: AppSpacing.sm),
            _buildQuickAddOption(
              context,
              icon: Icons.explore,
              title: '浏览发现页',
              description: '切换到"发现"标签浏览应用',
              onTap: () {
                try {
                  final homeLogic = Get.find();
                  homeLogic.jumpToPage(1);
                } catch (e) {
                  appLog.error('跳转失败: $e');
                }
              },
            ),
            const SizedBox(height: AppSpacing.sm),
            _buildQuickAddOption(
              context,
              icon: Icons.science_outlined,
              title: '我的频道',
              description: '管理已添加的应用频道',
              onTap: () {
                try {
                  final homeLogic = Get.find();
                  homeLogic.jumpToPage(2);
                } catch (e) {
                  appLog.error('跳转失败: $e');
                }
              },
            ),
            const SizedBox(height: AppSpacing.xl),
            FilledButton.icon(
              onPressed: onImportSample,
              icon: const Icon(Icons.download_rounded, size: 18),
              label: const Text('导入示例应用'),
              style: FilledButton.styleFrom(
                padding: AppSpacing.horizontalXL_verticalMD,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildQuickAddOption(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String description,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: AppRadius.allMD,
      child: AppCard(
        padding: AppSpacing.horizontalLG_verticalMD,
        border: Border.all(
          color: Theme.of(context).colorScheme.outlineVariant.withOpacity(0.5),
        ),
        borderRadius: AppRadius.allMD,
        onTap: onTap,
        child: Row(
          children: [
            Container(
              width: AppSpacing.xl + AppSpacing.xxl,
              height: AppSpacing.xl + AppSpacing.xxl,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primaryContainer,
                borderRadius: AppRadius.allSM,
              ),
              child: Icon(
                icon,
                color: Theme.of(context).colorScheme.primary,
                size: AppTypography.iconLG,
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: AppTypography.titleSmall.copyWith(
                          fontWeight: AppTypography.weightSemiBold,
                          color: Theme.of(context).colorScheme.onSurface,
                        ),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    description,
                    style: AppTypography.bodySmall.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right,
              color: AppColors.grey400,
            ),
          ],
        ),
      ),
    );
  }

  void _showQuickSearchGuide(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.search, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: AppSpacing.sm),
            const Text('快速搜索应用'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '点击上方的"快速搜索"按钮，然后：',
              style: AppTypography.bodyMedium,
            ),
            const SizedBox(height: AppSpacing.md),
            _buildGuideStep(context, '1', '选择要搜索的渠道'),
            _buildGuideStep(context, '2', '输入应用名称关键词'),
            _buildGuideStep(context, '3', '点击添加按钮添加应用'),
            const SizedBox(height: AppSpacing.md),
            Text(
              '💡 提示：也可以切换到"发现"页面浏览更多应用',
              style: AppTypography.bodySmall.copyWith(
                    color: AppColors.textSecondary,
                  ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  Widget _buildGuideStep(BuildContext context, String number, String text) {
    return Padding(
      padding: AppSpacing.onlyVerticalSM,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: AppSpacing.lg + AppSpacing.sm,
            height: AppSpacing.lg + AppSpacing.sm,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primary,
              shape: BoxShape.circle,
            ),
            child: Center(
              child: Text(
                number,
                style: AppTypography.labelMedium.copyWith(
                  color: Theme.of(context).colorScheme.onPrimary,
                  fontWeight: AppTypography.weightBold,
                ),
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Text(
              text,
              style: AppTypography.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }
}
