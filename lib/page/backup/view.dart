import 'package:flutter/material.dart';
import 'package:get/get.dart';

import 'package:gstore/core/core.dart';
import 'package:gstore/core/design/design_tokens.dart';

import 'logic.dart';
import 'state.dart';

class BackupPage extends StatefulWidget {
  const BackupPage({super.key});

  @override
  State<BackupPage> createState() => _BackupPageState();
}

class _BackupPageState extends State<BackupPage> {
  // 使用 Get.put 确保 BackupLogic 被初始化
  final BackupLogic _logic = Get.put<BackupLogic>(BackupLogic());

  /// WebDAV 模块是否在线（订阅模块上下线事件，驱动卡片显隐）
  bool _webdavModuleOnline = false;
  StreamSubscription<ModuleEvent>? _webdavSub;

  @override
  void initState() {
    super.initState();
    _webdavModuleOnline = ModuleManager.instance.isInitialized('webdav');
    _webdavSub = ModuleManager.instance.watchModule('webdav').listen((event) {
      if (!mounted) return;
      setState(() {
        _webdavModuleOnline = event.lifecycle == ModuleLifecycle.registered;
      });
    });
  }

  @override
  void dispose() {
    _webdavSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final logic = _logic;
    final state = logic.state;

    return Scaffold(
      appBar: AppBar(
        title: const Text('数据备份'),
      ),
      body: Obx(() => _buildBody(context, logic, state)),
    );
  }

  Widget _buildBody(
    BuildContext context,
    BackupLogic logic,
    BackupState state,
  ) {
    // 显示错误信息（如果有）
    if (state.errorMessage.value.isNotEmpty) {
      return Center(
        child: Padding(
          padding: AppSpacing.allXL,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.error_outline,
                size: AppTypography.iconXXXL,
                color: AppColors.error,
              ),
              const SizedBox(height: AppSpacing.lg),
              Text(
                '加载失败',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: AppSpacing.md),
              Text(
                state.errorMessage.value,
                style: Theme.of(context).textTheme.bodyMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: AppSpacing.xl),
              ElevatedButton(
                onPressed: () {
                  state.errorMessage.value = '';
                  logic.loadStatistics();
                },
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }

    return ListView(
      padding: AppSpacing.allLG,
      children: [
        // 统计信息卡片
        _buildStatisticsCard(context, logic, state),

        const SizedBox(height: AppSpacing.lg),

        // 备份恢复配置区域
        _buildBackupRestoreConfigCard(context, logic, state),

        const SizedBox(height: AppSpacing.lg),

        // 本地备份
        _buildLocalBackupCard(context, logic, state),

        // WebDAV 云端备份（模块下线时隐藏，含配置入口）
        if (_webdavModuleOnline) ...[
          const SizedBox(height: AppSpacing.lg),
          _buildWebDavBackupCard(context, logic, state),
        ],
      ],
    );
  }

  /// 统计信息卡片
  Widget _buildStatisticsCard(
    BuildContext context,
    BackupLogic logic,
    BackupState state,
  ) {
    return Obx(() {
      final stats = state.statistics.value;

      if (stats == null) {
        return const Center(
          child: AppLoading(size: AppLoadingSize.medium),
        );
      }

      return AppCard(
        padding: AppSpacing.allLG,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.bar_chart,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: AppSpacing.sm),
                Text(
                  '数据统计',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            _buildStatItem(
              context,
              '总应用数',
              '${stats!.totalApps}',
              Icons.apps,
            ),
            _buildStatItem(
              context,
              '已启用',
              '${stats.enabledApps}',
              Icons.check_circle,
            ),
            _buildStatItem(
              context,
              '已禁用',
              '${stats.disabledApps}',
              Icons.block,
            ),
          ],
        ),
      );
    });
  }

  Widget _buildStatItem(
    BuildContext context,
    String label,
    String value,
    IconData icon,
  ) {
    return Padding(
      padding: AppSpacing.onlyVerticalSM,
      child: Row(
        children: [
          Icon(icon, size: AppTypography.iconSM),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
          Text(
            value,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: Theme.of(context).colorScheme.primary,
                ),
          ),
        ],
      ),
    );
  }

  /// 备份恢复配置卡片
  Widget _buildBackupRestoreConfigCard(
    BuildContext context,
    BackupLogic logic,
    BackupState state,
  ) {
    return Obx(() {
      final restoreMode = state.restoreMode.value;

      return AppCard(
        padding: AppSpacing.allLG,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.settings_backup_restore,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: AppSpacing.sm),
                Text(
                  '备份与恢复配置',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),

            // 导出时是否包含应用配置
            SwitchListTile(
              title: const Text('导出时包含应用配置'),
              subtitle: const Text('导出备份时同时导出主题、WebDAV 等应用设置'),
              value: state.includeAppConfig.value,
              onChanged: (value) => logic.toggleIncludeAppConfig(value),
            ),

            const Divider(height: 1),

            // 导出内容选项（展开区域）
            ExpansionTile(
              title: const Text('导出内容选项'),
              subtitle: const Text('选择备份中包含哪些应用数据字段'),
              leading: const Icon(Icons.tune, size: AppTypography.iconMD),
              tilePadding: EdgeInsets.zero,
              childrenPadding: EdgeInsets.zero,
              children: [
                SwitchListTile(
                  dense: true,
                  title: const Text('包含图标 URL'),
                  value: state.includeIconUrls.value,
                  onChanged: (value) => logic.toggleIncludeIconUrls(value),
                ),
                SwitchListTile(
                  dense: true,
                  title: const Text('包含描述'),
                  value: state.includeDescription.value,
                  onChanged: (value) => logic.toggleIncludeDescription(value),
                ),
                SwitchListTile(
                  dense: true,
                  title: const Text('包含分类'),
                  value: state.includeCategory.value,
                  onChanged: (value) => logic.toggleIncludeCategory(value),
                ),
                SwitchListTile(
                  dense: true,
                  title: const Text('包含扩展字段 (extra)'),
                  value: state.includeExtra.value,
                  onChanged: (value) => logic.toggleIncludeExtra(value),
                ),
                SwitchListTile(
                  dense: true,
                  title: const Text('仅导出已启用的应用'),
                  value: state.enabledOnly.value,
                  onChanged: (value) => logic.toggleEnabledOnly(value),
                ),
              ],
            ),

            const Divider(height: 1),

            // 导入时是否恢复应用配置
            SwitchListTile(
              title: const Text('导入时恢复应用配置'),
              subtitle: const Text('导入备份时同时恢复主题、WebDAV 等应用设置'),
              value: state.restoreAppConfig.value,
              onChanged: (value) => logic.toggleRestoreAppConfig(value),
            ),

            const Divider(height: 1),

            // 恢复方式选择
            Padding(
              padding: AppSpacing.onlyTopMD,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '恢复方式',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  AppSegmentedButton<RestoreMode>(
                    value: restoreMode,
                    segments: const [
                      AppSegment(
                        value: RestoreMode.replace,
                        label: '覆盖',
                        icon: Icons.refresh,
                      ),
                      AppSegment(
                        value: RestoreMode.merge,
                        label: '合并',
                        icon: Icons.merge,
                      ),
                      AppSegment(
                        value: RestoreMode.update,
                        label: '更新',
                        icon: Icons.update,
                      ),
                    ],
                    onChanged: (RestoreMode newMode) {
                      logic.setRestoreMode(newMode);
                    },
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    _getRestoreModeDescription(restoreMode),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    });
  }

  String _getRestoreModeDescription(RestoreMode mode) {
    switch (mode) {
      case RestoreMode.replace:
        return '覆盖模式：清空所有已添加的应用，然后导入备份中的应用';
      case RestoreMode.merge:
        return '合并模式：只添加不存在的应用，不更新已存在的应用';
      case RestoreMode.update:
        return '更新模式：更新已存在的应用，并添加不存在的应用';
    }
  }

  /// 本地备份卡片
  Widget _buildLocalBackupCard(
    BuildContext context,
    BackupLogic logic,
    BackupState state,
  ) {
    return Obx(() {
      final isExporting = state.isExporting.value;
      final isImporting = state.isImporting.value;

      return AppCard(
        padding: EdgeInsets.zero,
        child: Column(
          children: [
            // 标题栏
            ListTile(
              leading: Icon(
                Icons.smartphone,
                color: Theme.of(context).colorScheme.primary,
              ),
              title: Text(
                '本地备份',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            const Divider(height: 1),

            // 导出到本地
            ListTile(
              leading: const Icon(Icons.save_alt),
              title: const Text('导出到本地'),
              subtitle: const Text('将备份数据保存到本地文件'),
              trailing: isExporting
                  ? const AppLoading(size: AppLoadingSize.small)
                  : const Icon(Icons.chevron_right),
              onTap: isExporting ? null : () => logic.exportCompressed(context),
            ),
            const Divider(height: 1),

            // 从本地文件恢复
            ListTile(
              leading: const Icon(Icons.folder_open),
              title: const Text('从本地文件恢复'),
              subtitle: const Text('选择本地备份文件进行恢复'),
              trailing: isImporting
                  ? const AppLoading(size: AppLoadingSize.small)
                  : const Icon(Icons.chevron_right),
              onTap: isImporting ? null : () => logic.selectAndImportFile(context),
            ),
          ],
        ),
      );
    });
  }

  /// WebDAV 云端备份卡片
  Widget _buildWebDavBackupCard(
    BuildContext context,
    BackupLogic logic,
    BackupState state,
  ) {
    return Obx(() {
      final hasConfig = state.hasWebDavConfig.value;
      final isExporting = state.isUploadingWebDav.value;
      final isImporting = state.isImporting.value;
      final status = state.webDavStatus.value;

      // 根据配置状态决定卡片是否可用
      final isEnabled = hasConfig;

      return Opacity(
        opacity: isEnabled ? 1.0 : 0.5,
        child: AppCard(
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              // 标题栏
              ListTile(
                leading: Icon(
                  Icons.cloud_outlined,
                  color: isEnabled
                      ? Theme.of(context).colorScheme.primary
                      : Theme.of(context).colorScheme.outlineVariant,
                ),
                title: Text(
                  'WebDAV 云端备份',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: isEnabled
                            ? null
                            : Theme.of(context).colorScheme.outlineVariant,
                      ),
                ),
                trailing: _buildStatusIndicator(status),
                onTap: () async {
                  final result = await Get.toNamed(AppRoute.webdavConfig);
                  if (result == true) {
                    await logic.checkWebDavConfig();
                  }
                },
              ),
              const Divider(height: 1),

              // 备份到网盘
              ListTile(
                leading: const Icon(Icons.cloud_upload),
                title: const Text('备份到网盘'),
                subtitle: Text(
                  hasConfig
                      ? '将备份数据上传到 WebDAV 云端'
                      : '请先配置 WebDAV 信息',
                ),
                trailing: isExporting
                    ? const AppLoading(size: AppLoadingSize.small)
                    : const Icon(Icons.chevron_right),
                onTap: isEnabled && !isExporting
                    ? () => logic.uploadToWebDav(context, compressed: true)
                    : null,
              ),
              const Divider(height: 1),

              // 从网盘恢复备份
              ListTile(
                leading: const Icon(Icons.cloud_download),
                title: const Text('从网盘恢复备份'),
                subtitle: Text(
                  hasConfig
                      ? '从 WebDAV 云端下载备份并恢复'
                      : '请先配置 WebDAV 信息',
                ),
                trailing: isImporting
                    ? const AppLoading(size: AppLoadingSize.small)
                    : const Icon(Icons.chevron_right),
                onTap: isEnabled && !isImporting
                    ? () => logic.downloadFromWebDav(context)
                    : null,
              ),
            ],
          ),
        ),
      );
    });
  }

  /// 构建状态指示器
  Widget _buildStatusIndicator(WebDavConnectionStatus status) {
    Color color;
    double size;

    switch (status) {
      case WebDavConnectionStatus.notConfigured:
        color = AppColors.grey400;
        size = 8;
        break;
      case WebDavConnectionStatus.connected:
        color = AppColors.success;
        size = 8;
        break;
      case WebDavConnectionStatus.failed:
        color = AppColors.error;
        size = 8;
        break;
      case WebDavConnectionStatus.testing:
        color = AppColors.info;
        size = 12;
        break;
    }

    if (status == WebDavConnectionStatus.testing) {
      return AppLoading(
        size: AppLoadingSize.small,
        color: AppColors.info,
      );
    }

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
      ),
    );
  }
}
