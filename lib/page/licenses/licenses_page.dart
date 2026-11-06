import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';

import 'package:gstore/core/core.dart';
import 'package:gstore/core/licenses/license_bundle.dart';

/// 开源许可页：列出应用依赖的全部第三方包及其开源许可证。
///
/// 数据由 `dart_pubspec_licenses` 生成后压缩为
/// `assets/licenses/oss_licenses.json.gz`（见 `tool/dump_licenses.dart`），
/// 页面按需解压加载，避免把整个许可证清单编译进 AOT 快照。
class LicensesPage extends StatefulWidget {
  const LicensesPage({super.key});

  @override
  State<LicensesPage> createState() => _LicensesPageState();

  /// 从许可证文本提取简短类型标签（取首行并截断）。
  static String licenseLabelOf(LicensePackage pkg) {
    final license = pkg.license ?? '';
    if (license.isEmpty) return '未标注';
    final firstLine = license.trim().split('\n').first.trim();
    if (firstLine.isEmpty) return '开源许可';
    return firstLine.length > 24 ? '${firstLine.substring(0, 24)}…' : firstLine;
  }
}

class _LicensesPageState extends State<LicensesPage> {
  late final Future<LicenseBundle> _bundle = _loadBundle();

  Future<LicenseBundle> _loadBundle() async {
    final data = await rootBundle.load('assets/licenses/oss_licenses.json.gz');
    return LicenseBundle.decode(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('开源许可')),
      body: FutureBuilder<LicenseBundle>(
        future: _bundle,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: AppLoading());
          }
          final bundle = snapshot.data;
          if (snapshot.hasError || bundle == null) {
            return Center(
              child: Text(
                '许可证加载失败',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            );
          }
          // 无许可的排最后（多数为未知，放底部不干扰）
          final packages = [...bundle.packages]..sort((a, b) {
              final aHas = a.license?.isNotEmpty == true;
              final bHas = b.license?.isNotEmpty == true;
              if (aHas != bHas) return aHas ? -1 : 1;
              return a.name.toLowerCase().compareTo(b.name.toLowerCase());
            });

          return ListView.separated(
            padding: const EdgeInsets.only(bottom: AppSpacing.xl),
            itemCount: packages.length + 1,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, index) {
              if (index == 0) {
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
              return _buildLicenseRow(context, packages[index - 1]);
            },
          );
        },
      ),
    );
  }

  Widget _buildLicenseRow(BuildContext context, LicensePackage pkg) {
    final theme = Theme.of(context);
    final hasLicense = pkg.license?.isNotEmpty == true;
    final licenseLabel = LicensesPage.licenseLabelOf(pkg);

    return ListTile(
      leading: Icon(
        TablerIcons.file_description,
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
          ? const Icon(TablerIcons.chevron_right, size: AppTypography.iconSM)
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

}

/// 单个包许可证详情页。
class LicenseDetailPage extends StatelessWidget {
  const LicenseDetailPage({super.key, required this.pkg});

  final LicensePackage pkg;

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
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: 4),
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
