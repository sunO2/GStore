import 'package:flutter/material.dart';
import '../../../core/core.dart';

/// 步骤配置 Mixin
/// 提供配置UI构建的通用方法
mixin StepConfigMixin {
  /// 通用文本输入
  Widget buildTextField({
    required BuildContext context,
    required String label,
    required String initialValue,
    String? hintText,
    int maxLines = 1,
    required Function(String) onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 4),
        TextFormField(
          initialValue: initialValue,
          maxLines: maxLines,
          style: const TextStyle(fontSize: 12),
          decoration: InputDecoration(
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            border: const OutlineInputBorder(),
            hintText: hintText,
            hintStyle: TextStyle(fontSize: 11, color: AppColors.textSecondary),
          ),
          onChanged: onChanged,
        ),
      ],
    );
  }

  /// 通用下拉选择
  Widget buildDropdown<T>({
    required BuildContext context,
    required String label,
    required T value,
    required List<DropdownMenuItem<T>> items,
    required Function(T?) onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 4),
        DropdownButtonFormField<T>(
          value: value,
          isExpanded: true,
          decoration: const InputDecoration(
            isDense: true,
            contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            border: OutlineInputBorder(),
          ),
          items: items,
          onChanged: onChanged,
        ),
      ],
    );
  }

  /// 分隔线
  Widget buildDivider(BuildContext context) {
    return Column(
      children: [
        const SizedBox(height: AppSpacing.md),
        Divider(height: 1, color: Theme.of(context).colorScheme.outlineVariant),
        const SizedBox(height: AppSpacing.md),
      ],
    );
  }

  /// 构建输入输出配置容器
  Widget buildInputOutputContainer({
    required BuildContext context,
    required String title,
    required IconData icon,
    required List<Widget> children,
  }) {
    return Container(
      padding: AppSpacing.allSM,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
        borderRadius: AppRadius.allSM,
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 14, color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: 6),
              Text(
                title,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          ...children,
        ],
      ),
    );
  }

  /// 获取 HTTP 方法选项
  List<DropdownMenuItem<String>> getHttpMethodItems() {
    return ['GET', 'POST', 'PUT', 'DELETE', 'PATCH'].map((m) {
      return DropdownMenuItem(value: m, child: Text(m, style: const TextStyle(fontSize: 12)));
    }).toList();
  }

  /// 获取 Body 类型选项
  List<DropdownMenuItem<String>> getBodyTypeItems() {
    return const [
      DropdownMenuItem(value: 'none', child: Text('None', style: TextStyle(fontSize: 12))),
      DropdownMenuItem(value: 'json', child: Text('Raw JSON', style: TextStyle(fontSize: 12))),
      DropdownMenuItem(value: 'form', child: Text('Form Data', style: TextStyle(fontSize: 12))),
      DropdownMenuItem(value: 'urlencoded', child: Text('x-www-form-urlencoded', style: TextStyle(fontSize: 12))),
      DropdownMenuItem(value: 'text', child: Text('Raw Text', style: TextStyle(fontSize: 12))),
    ];
  }

  /// 获取过滤操作符选项
  List<DropdownMenuItem<String>> getFilterOperatorItems() {
    return const [
      DropdownMenuItem(value: 'eq', child: Text('eq', style: TextStyle(fontSize: 12))),
      DropdownMenuItem(value: 'ne', child: Text('ne', style: TextStyle(fontSize: 12))),
      DropdownMenuItem(value: 'gt', child: Text('gt', style: TextStyle(fontSize: 12))),
      DropdownMenuItem(value: 'lt', child: Text('lt', style: TextStyle(fontSize: 12))),
      DropdownMenuItem(value: 'gte', child: Text('gte', style: TextStyle(fontSize: 12))),
      DropdownMenuItem(value: 'lte', child: Text('lte', style: TextStyle(fontSize: 12))),
      DropdownMenuItem(value: 'contains', child: Text('contains', style: TextStyle(fontSize: 12))),
      DropdownMenuItem(value: 'startsWith', child: Text('startsWith', style: TextStyle(fontSize: 12))),
      DropdownMenuItem(value: 'endsWith', child: Text('endsWith', style: TextStyle(fontSize: 12))),
    ];
  }
}
