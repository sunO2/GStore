import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/channel/channel.dart';
import 'package:gstore/core/icons/Icons.dart';
import 'package:gstore/core/design/design_tokens.dart';

import 'logic.dart';
import 'state.dart';

class ChannelTestPage extends StatelessWidget {
  ChannelTestPage({super.key});

  final ChannelTestLogic logic = Get.put(ChannelTestLogic());
  final ChannelTestState state = Get.find<ChannelTestLogic>().state;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Obx(() => Text(
              state.developerMode.value ? '频道测试' : '频道管理',
            )),
        elevation: AppShadows.elevationNone,
        actions: [
          // 开发者模式切换
          Obx(() => IconButton(
                icon: Icon(
                  state.developerMode.value
                      ? Icons.bug_report
                      : Icons.bug_report_outlined,
                ),
                tooltip: '开发者模式',
                onPressed: () => logic.toggleDeveloperMode(),
              )),
          Obx(() => IconButton(
                onPressed: state.isQuerying.value ? null : logic.refresh,
                icon: state.isQuerying.value
                    ? const AppLoading(size: AppLoadingSize.small)
                    : const Icon(Icons.refresh),
              )),
          PopupMenuButton<String>(
            onSelected: (value) async {
              switch (value) {
                case 'refresh':
                  await logic.refresh();
                  break;
                case 'clear_cache':
                  await logic.clearCache();
                  break;
                case 'check_available':
                  _checkAvailableChannels(context);
                  break;
                case 'workflow_designer':
                  Get.toNamed(AppRoute.workflowDesigner);
                  break;
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: 'refresh',
                child: Row(
                  children: [
                    Icon(Icons.refresh, size: AppTypography.iconSM),
                    SizedBox(width: AppSpacing.sm),
                    Text('刷新数据'),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'clear_cache',
                child: Row(
                  children: [
                    Icon(Icons.delete_outline, size: AppTypography.iconSM),
                    SizedBox(width: AppSpacing.sm),
                    Text('清除缓存'),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'check_available',
                child: Row(
                  children: [
                    Icon(Icons.check_circle_outline, size: AppTypography.iconSM),
                    SizedBox(width: AppSpacing.sm),
                    Text('检查可用性'),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'workflow_designer',
                child: Row(
                  children: [
                    Icon(Icons.account_tree, size: AppTypography.iconSM),
                    SizedBox(width: AppSpacing.sm),
                    Text('工作流设计器'),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: Obx(() => state.developerMode.value
          ? _buildDeveloperView(context)
          : _buildUserView(context)),
    );
  }

  /// 渠道选择器
  Widget _buildChannelSelector(BuildContext context) {
    return Container(
      padding: AppSpacing.allLG,
      color: Theme.of(context).colorScheme.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '选择渠道',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          SizedBox(height: AppSpacing.md),
          Obx(() => Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.sm,
                children: logic.channelList.map((info) {
                  final isSelected = state.selectedChannel.value == info.type;
                  return FilterChip(
                    label: Text(info.name),
                    avatar: Icon(
                      logic.getChannelIcon(info.type),
                      size: AppTypography.iconSM,
                    ),
                    selected: isSelected,
                    onSelected: (selected) {
                      if (selected) {
                        logic.switchChannel(info.type);
                      }
                    },
                    selectedColor: Theme.of(context).colorScheme.primaryContainer,
                    showCheckmark: false,
                  );
                }).cast<Widget>().toList(),
              )),
        ],
      ),
    );
  }

  /// 操作面板
  Widget _buildOperationPanel(BuildContext context) {
    return Container(
      padding: AppSpacing.allLG,
      color: Theme.of(context).colorScheme.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '操作',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          SizedBox(height: AppSpacing.md),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: [
              _buildOperationChip('getAllApps', '获取所有应用'),
              _buildOperationChip('getAppInfo', '获取应用详情'),
              _buildOperationChip('searchApps', '搜索应用'),
              _buildOperationChip('searchByCategory', '按分类搜索'),
              _buildOperationChip('getAllCategories', '获取分类'),
              _buildOperationChip('checkUpdate', '检查更新'),
              _buildOperationChip('checkAllUpdates', '检查所有更新'),
            ],
          ),

          // 参数输入
          _buildParameterInputs(context),
        ],
      ),
    );
  }

  /// 操作按钮
  Widget _buildOperationChip(String value, String label) {
    return Obx(() {
      final isSelected = state.operationType.value == value;
      return ActionChip(
        avatar: isSelected
            ? const Icon(Icons.check, size: AppTypography.iconSM)
            : const Icon(Icons.play_arrow, size: AppTypography.iconSM),
        label: Text(label),
        onPressed: state.isQuerying.value
            ? null
            : () => logic.executeQuery(value),
        backgroundColor: isSelected
            ? Theme.of(Get.context!).colorScheme.primaryContainer
            : null,
      );
    });
  }

  /// 参数输入区域
  Widget _buildParameterInputs(BuildContext context) {
    return Obx(() {
      // 根据操作类型显示不同的输入框
      switch (state.operationType.value) {
        case 'searchApps':
          return Padding(
            padding: AppSpacing.onlyTopMD,
            child: TextField(
              decoration: const InputDecoration(
                labelText: '搜索关键词',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: (value) => state.searchKeyword.value = value,
            ),
          );
        case 'getAppInfo':
          return Padding(
            padding: AppSpacing.onlyTopMD,
            child: TextField(
              decoration: const InputDecoration(
                labelText: '应用 ID',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: (value) => state.appId.value = value,
            ),
          );
        case 'searchByCategory':
          return Padding(
            padding: AppSpacing.onlyTopMD,
            child: TextField(
              decoration: const InputDecoration(
                labelText: '分类 ID (如: Tools)',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: (value) => state.categoryId.value = value,
            ),
          );
        default:
          return const SizedBox.shrink();
      }
    });
  }

  /// 结果显示区域
  Widget _buildResultArea(BuildContext context) {
    return Obx(() {
      if (state.isQuerying.value) {
        return const LoadingState();
      }

      if (state.errorMessage.value.isNotEmpty) {
        return Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.error_outline,
                size: AppTypography.iconXXXL,
                color: AppColors.error,
              ),
              SizedBox(height: AppSpacing.lg),
              Text(
                state.errorMessage.value,
                style: Theme.of(context).textTheme.bodyMedium,
                textAlign: TextAlign.center,
              ),
            ],
          ),
        );
      }

      final result = state.queryResult.value;
      if (result == null) {
        return Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.touch_app_outlined,
                size: AppTypography.iconXXXL,
                color: AppColors.withOpacity(Theme.of(context).colorScheme.primary, 0.5),
              ),
              SizedBox(height: AppSpacing.lg),
              Text(
                '选择操作并执行查询',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: AppColors.textSecondary,
                    ),
              ),
            ],
          ),
        );
      }

      // 显示查询结果
      return Column(
        children: [
          // 结果元信息
          _buildResultMeta(context, result),

          // 应用列表或详情
          Expanded(
            child: _buildResultContent(context, result),
          ),
        ],
      );
    });
  }

  /// 结果元信息
  Widget _buildResultMeta(BuildContext context, ChannelResult result) {
    return Container(
      padding: AppSpacing.allMD,
      color: AppColors.withOpacity(Theme.of(context).colorScheme.surfaceVariant, 0.3),
      child: Row(
        children: [
          Icon(
            result.success ? Icons.check_circle : Icons.error,
            size: AppTypography.iconSM,
            color: result.success ? AppColors.success : AppColors.error,
          ),
          SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              '${result.from.code} | ${result.success ? "成功" : "失败"}'
              '${result.fromCache ? " | 缓存" : ""}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          if (result.metadata?['count'] != null)
            Text(
              '${result.metadata!['count']} 项',
              style: Theme.of(context).textTheme.bodySmall,
            ),
        ],
      ),
    );
  }

  /// 结果内容
  Widget _buildResultContent(BuildContext context, ChannelResult result) {
    if (state.operationType.value == 'checkAllUpdates') {
      return Center(
        child: Padding(
          padding: AppSpacing.allLG,
          child: Text(
            result.metadata?['summary'] ?? '无结果',
            style: Theme.of(context).textTheme.bodyMedium,
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    if (state.operationType.value == 'checkUpdate') {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              result.data == true ? Icons.system_update : Icons.check_circle,
              size: AppTypography.iconXXXL,
              color: result.data == true ? AppColors.warning : AppColors.success,
            ),
            SizedBox(height: AppSpacing.lg),
            Text(
              result.data == true ? '有新版本可用' : '已是最新版本',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (result.metadata?['currentVersion'] != null)
              Padding(
                padding: AppSpacing.onlyTopMD,
                child: Text(
                  '当前版本: ${result.metadata!['currentVersion']}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
          ],
        ),
      );
    }

    if (state.apps.isEmpty) {
      return Center(
        child: Text(
          '无数据',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: AppColors.grey500,
              ),
        ),
      );
    }

    return ListView.builder(
      padding: AppSpacing.allSM,
      itemCount: state.apps.length,
      itemBuilder: (context, index) {
        final app = state.apps[index];
        return Card(
          margin: AppSpacing.onlyBottomSM,
          child: ListTile(
            leading: app.icon.isNotEmpty
                ? CircleAvatar(
                    backgroundImage: NetworkImage(app.icon),
                  )
                : const CircleAvatar(
                    child: Icon(Icons.app_settings_alt),
                  ),
            title: Text(app.name),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(app.appId),
                if (app.des.isNotEmpty)
                  Text(
                    app.des,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
            trailing: Chip(
              label: Text(
                app.category?.first ?? '未分类',
                style: const TextStyle(fontSize: AppTypography.sizeXXS),
              ),
              visualDensity: VisualDensity.compact,
            ),
          ),
        );
      },
    );
  }

  /// 普通用户视图 - 简洁的频道状态展示
  Widget _buildUserView(BuildContext context) {
    return ListView(
      padding: AppSpacing.allLG,
      children: [
        // 欢迎卡片
        AppCard(
          elevation: AppShadows.elevationSM,
          child: Padding(
            padding: AppSpacing.allLG,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.info_outline,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    SizedBox(width: AppSpacing.sm),
                    Text(
                      '频道管理',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                            fontWeight: AppTypography.weightBold,
                          ),
                    ),
                  ],
                ),
                SizedBox(height: AppSpacing.md),
                Text(
                  '查看已配置的应用渠道状态，管理应用来源',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: AppColors.grey700,
                      ),
                ),
                SizedBox(height: AppSpacing.sm),
                Text(
                  '💡 点击右上角的 🐛 图标可进入开发者模式',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: AppColors.grey500,
                      ),
                ),
              ],
            ),
          ),
        ),

        SizedBox(height: AppSpacing.lg),

        // 频道状态卡片
        _buildChannelStatusCard(context),

        SizedBox(height: AppSpacing.lg),

        // 使用提示
        _buildUsageTips(context),

        SizedBox(height: AppSpacing.xxl),

        // 快速操作
        _buildQuickActions(context),
      ],
    );
  }

  /// 频道状态卡片
  Widget _buildChannelStatusCard(BuildContext context) {
    final manager = ChannelManager.instance;
    final channels = manager.allChannelInfo;

    return AppCard(
      elevation: AppShadows.elevationSM,
      child: Padding(
        padding: AppSpacing.allLG,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.dashboard,
                  color: Theme.of(context).colorScheme.primary,
                ),
                SizedBox(width: AppSpacing.sm),
                Text(
                  '频道状态',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: AppTypography.weightBold,
                      ),
                ),
              ],
            ),
            const Divider(height: AppSpacing.xxl),
            ...channels.map((info) => _buildChannelStatusItem(context, info)),
          ],
        ),
      ),
    );
  }

  /// 频道状态项
  Widget _buildChannelStatusItem(BuildContext context, ChannelInfo info) {
    return Container(
      padding: AppSpacing.onlyVerticalMD,
      child: Row(
        children: [
          // 图标
          Container(
            width: AppSpacing.xl + AppSpacing.xxl,
            height: AppSpacing.xl + AppSpacing.xxl,
            decoration: BoxDecoration(
              color: info.enabled
                  ? AppColors.withOpacity(_getChannelColor(info.type), 0.1)
                  : AppColors.grey100,
              borderRadius: AppRadius.allSM,
            ),
            child: Icon(
              logic.getChannelIcon(info.type),
              color: info.enabled ? _getChannelColor(info.type) : AppColors.grey500,
            ),
          ),
          SizedBox(width: AppSpacing.md),
          // 信息
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  info.name,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: AppTypography.weightBold,
                      ),
                ),
                SizedBox(height: AppSpacing.xs),
                Text(
                  info.description,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: AppColors.grey600,
                      ),
                ),
              ],
            ),
          ),
          // 状态标签
          _buildStatusChip(context, info),
        ],
      ),
    );
  }

  /// 状态标签
  Widget _buildStatusChip(BuildContext context, ChannelInfo info) {
    final isEnabled = info.enabled;
    final color = isEnabled ? AppColors.success : AppColors.grey500;

    return Container(
      padding: AppSpacing.chipPadding,
      decoration: BoxDecoration(
        color: AppColors.withOpacity(color, 0.1),
        borderRadius: AppRadius.allMD,
        border: Border.all(color: color),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isEnabled ? Icons.check_circle : Icons.block,
            size: AppTypography.iconXS,
            color: color,
          ),
          SizedBox(width: AppSpacing.xs),
          Text(
            isEnabled ? '已启用' : '已禁用',
            style: TextStyle(
              color: color,
              fontSize: AppTypography.sizeXS,
              fontWeight: AppTypography.weightBold,
            ),
          ),
        ],
      ),
    );
  }

  /// 使用提示
  Widget _buildUsageTips(BuildContext context) {
    return AppCard(
      backgroundColor: AppColors.withOpacity(Theme.of(context).colorScheme.primaryContainer, 0.3),
      child: Padding(
        padding: AppSpacing.allLG,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.lightbulb_outline,
                  color: Theme.of(context).colorScheme.primary,
                ),
                SizedBox(width: AppSpacing.sm),
                Text(
                  '使用提示',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: AppTypography.weightBold,
                      ),
                ),
              ],
            ),
            SizedBox(height: AppSpacing.md),
            _buildTipItem(context, '在"发现"页面浏览和添加应用'),
            _buildTipItem(context, '点击搜索栏快速搜索特定渠道的应用'),
            _buildTipItem(context, '已添加的应用会显示在"首页"'),
            _buildTipItem(context, '点击右上角 🐛 图标进入开发者模式'),
          ],
        ),
      ),
    );
  }

  /// 提示项
  Widget _buildTipItem(BuildContext context, String tip) {
    return Padding(
      padding: AppSpacing.onlyVerticalXS,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.arrow_right,
            size: AppTypography.iconSM,
            color: Theme.of(context).colorScheme.primary,
          ),
          SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              tip,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }

  /// 快速操作
  Widget _buildQuickActions(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '快速操作',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: AppTypography.weightBold,
              ),
        ),
        SizedBox(height: AppSpacing.md),
        Row(
          children: [
            Expanded(
              child: _buildActionButton(
                context,
                icon: Icons.refresh,
                label: '刷新数据',
                onTap: () => logic.refresh(),
              ),
            ),
            SizedBox(width: AppSpacing.md),
            Expanded(
              child: _buildActionButton(
                context,
                icon: Icons.delete_outline,
                label: '清除缓存',
                onTap: () => logic.clearCache(),
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// 操作按钮
  Widget _buildActionButton(
    BuildContext context, {
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: AppRadius.allMD,
      child: Container(
        padding: AppSpacing.onlyVerticalLG,
        decoration: BoxDecoration(
          border: Border.all(color: AppColors.grey300),
          borderRadius: AppRadius.allMD,
        ),
        child: Column(
          children: [
            Icon(icon, color: Theme.of(context).colorScheme.primary),
            SizedBox(height: AppSpacing.sm),
            Text(
              label,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  /// 开发者视图 - 保留原有的测试功能
  Widget _buildDeveloperView(BuildContext context) {
    return Column(
      children: [
        // 开发者模式提示
        Container(
          padding: AppSpacing.horizontalLG_verticalSM,
          color: AppColors.warningLight,
          child: Row(
            children: [
              const Icon(Icons.developer_mode, size: AppTypography.iconSM),
              SizedBox(width: AppSpacing.sm),
              Text(
                '开发者模式 - 用于测试和调试',
                style: TextStyle(
                  color: AppColors.warningDark,
                  fontWeight: AppTypography.weightBold,
                ),
              ),
            ],
          ),
        ),
        // 渠道选择器
        _buildChannelSelector(context),
        const Divider(height: 1),

        // 操作面板
        _buildOperationPanel(context),
        const Divider(height: 1),

        // 结果显示
        Expanded(
          child: _buildResultArea(context),
        ),
      ],
    );
  }

  /// 获取渠道颜色
  Color _getChannelColor(ChannelType type) {
    return AppColors.getChannelBrandColor(type.name);
  }

  /// 检查可用渠道
  void _checkAvailableChannels(BuildContext context) async {
    final manager = Get.find(tag: 'channelManager');
    final available = await manager.checkAvailableChannels();

    if (context.mounted) {
      Get.dialog(
        AlertDialog(
          title: const Text('可用渠道'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var type in available)
                Padding(
                  padding: AppSpacing.onlyVerticalXS,
                  child: Row(
                    children: [
                      const Icon(Icons.check_circle, color: AppColors.success, size: AppTypography.iconSM),
                      SizedBox(width: AppSpacing.sm),
                      Text(type.code),
                    ],
                  ),
                ),
              if (available.isEmpty) const Text('无可用渠道'),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Get.back(),
              child: const Text('关闭'),
            ),
          ],
        ),
      );
    }
  }
}
