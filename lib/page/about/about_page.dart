import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' show WebUri;
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:go_router/go_router.dart';

import 'package:gstore/core/core.dart';
import 'package:gstore/page/web/browser.dart';

/// 项目主页（README / Release 徽章使用同一地址）。
const String kProjectHomepage = 'https://github.com/sunO2/GStore';

/// 关于页：应用信息、项目入口与本地诊断/数据维护入口。
///
/// 从「我的 → 设置」下方进入；查看日志与数据库管理集中在这里，
/// 避免散落在「工具」和「设置」两处。
class AboutPage extends StatefulWidget {
  const AboutPage({super.key});

  @override
  State<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends State<AboutPage> {
  late final Future<String?> _version = AppVersionService.versionName();

  void _openProjectHomepage() {
    unawaited(GStoreInAppBrowser().open(url: WebUri(kProjectHomepage)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('关于')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: AppSpacing.xl),
        children: [
          _buildHeader(context),
          _buildSectionHeader(context, '应用信息'),
          _buildAppInfoCard(context),
          const SizedBox(height: AppSpacing.xxl),
          _buildSectionHeader(context, '诊断与数据'),
          _buildDiagnosticsCard(context),
          const SizedBox(height: AppSpacing.xxl),
          Center(
            child: Text(
              'GStore · Flutter + Rust',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: AppSpacing.allLG,
      child: Padding(
        padding: AppSpacing.allLG,
        child: Row(
          children: [
            Container(
              width: AppSpacing.xxl + AppSpacing.xl,
              height: AppSpacing.xxl + AppSpacing.xl,
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(AppSpacing.md),
              ),
              child: Icon(
                TablerIcons.apps,
                size: AppTypography.iconLG,
                color: theme.colorScheme.onPrimaryContainer,
              ),
            ),
            const SizedBox(width: AppSpacing.lg),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'GStore',
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: AppTypography.weightSemiBold,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    '开源 Android 应用商店',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  FutureBuilder<String?>(
                    future: _version,
                    builder: (context, snapshot) {
                      final version = snapshot.data;
                      final label =
                          snapshot.connectionState == ConnectionState.waiting
                              ? '版本读取中…'
                              : version == null || version.isEmpty
                                  ? '版本未知'
                                  : '版本 $version';
                      return Text(
                        label,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionHeader(BuildContext context, String title) {
    return Padding(
      padding: AppSpacing.onlyHorizontalLG,
      child: Text(
        title,
        style: TextStyle(
          fontSize: AppTypography.sizeSM,
          fontWeight: AppTypography.weightMedium,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  Widget _buildAppInfoCard(BuildContext context) {
    return Card(
      margin: AppSpacing.allLG,
      child: Column(
        children: [
          ListTile(
            leading: const Icon(TablerIcons.world, size: AppTypography.iconMD),
            title: const Text('项目主页'),
            subtitle: const Text(kProjectHomepage),
            trailing: const Icon(TablerIcons.chevron_right,
                size: AppTypography.iconSM),
            onTap: _openProjectHomepage,
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(TablerIcons.file_description,
                size: AppTypography.iconMD),
            title: const Text('开源许可'),
            subtitle: const Text('第三方依赖的许可证清单'),
            trailing: const Icon(TablerIcons.chevron_right,
                size: AppTypography.iconSM),
            onTap: () => context.push(AppRoute.licenses),
          ),
        ],
      ),
    );
  }

  Widget _buildDiagnosticsCard(BuildContext context) {
    return Card(
      margin: AppSpacing.allLG,
      child: Column(
        children: [
          ListTile(
            leading: const Icon(TablerIcons.bug, size: AppTypography.iconMD),
            title: const Text('查看日志'),
            subtitle: const Text('查看应用运行日志并导出'),
            trailing: const Icon(TablerIcons.chevron_right,
                size: AppTypography.iconSM),
            onTap: () => context.push(AppRoute.logViewer),
          ),
          const Divider(height: 1),
          ListTile(
            leading:
                const Icon(TablerIcons.database, size: AppTypography.iconMD),
            title: const Text('数据库管理'),
            subtitle: const Text('浏览本地 SQLite 数据库，含 Rust 核心库'),
            trailing: const Icon(TablerIcons.chevron_right,
                size: AppTypography.iconSM),
            onTap: () => context.push(AppRoute.databaseManage),
          ),
        ],
      ),
    );
  }
}
