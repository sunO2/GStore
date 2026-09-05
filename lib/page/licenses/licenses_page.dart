import 'package:flutter/material.dart';

import 'package:gstore/core/core.dart';
import 'package:gstore/oss_licenses.dart' as oss;

/// 开源许可页：列出应用依赖的全部第三方包及其开源许可证。
///
/// 数据由 `dart_pubspec_licenses` 生成（`dart run dart_pubspec_licenses:generate`
/// 输出 lib/oss_licenses.dart，基于 pubspec.lock 离线生成，无需网络）。
class LicensesPage extends StatelessWidget {
  const LicensesPage({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 全部依赖（含传递依赖）；按名称排序便于检索
    final packages = [...oss.allDependencies]..sort((a, b) {
        // 无许可的排最后（多数为未知，放底部不干扰）
        final aHas = a.license?.isNotEmpty == true;
        final bHas = b.license?.isNotEmpty == true;
        if (aHas != bHas) return aHas ? -1 : 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });

    return Scaffold(
      appBar: AppBar(title: const Text('开源许可')),
      body: ListView.separated(
        padding: const EdgeInsets.only(bottom: AppSpacing.xl),
        itemCount: packages.length + 1,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (context, index) {
          if (index == 0) {
            // 顶部说明
            return Padding(
              padding: AppSpacing.allLG,
              child: Text(
                '本项目依赖以下开源软件，遵循各自许可证。'
                '共 ${packages.length} 个依赖包。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            );
          }
          final pkg = packages[index - 1];
          return _buildLicenseRow(context, pkg);
        },
      ),
    );
  }

  Widget _buildLicenseRow(BuildContext context, oss.Package pkg) {
    final theme = Theme.of(context);
    final hasLicense = pkg.license?.isNotEmpty == true;
    // 许可证标签：取许可证文本首行（通常即 "MIT License"/"Apache License" 等）
    final licenseLabel = licenseLabelOf(pkg);

    return ListTile(
      leading: Icon(
        Icons.description_outlined,
        color: hasLicense
            ? theme.colorScheme.primary
            : theme.colorScheme.outline,
      ),
      title: Text(
        pkg.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        [
          if (pkg.version?.isNotEmpty == true) pkg.version!,
          licenseLabel,
          if (pkg.isSdk) 'SDK',
        ].join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: hasLicense
          ? const Icon(Icons.chevron_right, size: AppTypography.iconSM)
          : null,
      onTap: hasLicense
          ? () {
              Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => LicenseDetailPage(pkg: pkg),
              ));
            }
          : null,
    );
  }

  /// 从许可证文本提取简短类型标签（取首行并截断）。
  static String licenseLabelOf(oss.Package pkg) {
    final license = pkg.license ?? '';
    if (license.isEmpty) return '未标注';
    final firstLine = license.trim().split('\n').first.trim();
    if (firstLine.isEmpty) return '开源许可';
    return firstLine.length > 24 ? '${firstLine.substring(0, 24)}…' : firstLine;
  }
}

/// 单个包许可证详情页。
class LicenseDetailPage extends StatelessWidget {
  const LicenseDetailPage({super.key, required this.pkg});

  final oss.Package pkg;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final license = pkg.license ?? '';
    final hasLicense = license.isNotEmpty;

    return Scaffold(
      appBar: AppBar(title: Text(pkg.name)),
      body: ListView(
        padding: AppSpacing.allLG,
        children: [
          // 包元信息
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: [
              if (pkg.version?.isNotEmpty == true)
                _chip(theme, '版本 ${pkg.version}'),
              if (hasLicense) _chip(theme, LicensesPage.licenseLabelOf(pkg)),
            ],
          ),
          if (pkg.repository != null || pkg.homepage != null) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(
              [
                if (pkg.repository != null) pkg.repository!,
                if (pkg.homepage != null && pkg.homepage != pkg.repository)
                  pkg.homepage!,
              ].join('\n'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
          ],
          const SizedBox(height: AppSpacing.lg),
          // 许可全文（许可证文本基本为纯文本；罕见 markdown 原样展示即可）
          if (license.isNotEmpty)
            SelectableText(
              license,
              style: theme.textTheme.bodySmall?.copyWith(height: 1.5),
            )
          else
            Text(
              '该包未提供许可证文本。',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
    );
  }

  Widget _chip(ThemeData theme, String text) {
    return Container(
      padding:
          EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Text(
        text,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSecondaryContainer,
        ),
      ),
    );
  }
}
