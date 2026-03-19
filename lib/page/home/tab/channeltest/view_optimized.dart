/// 优化后的我的频道页面
/// 简化为普通用户视图，隐藏复杂测试功能
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:gstore/core/channel/channel.dart';
import 'package:gstore/core/icons/Icons.dart';

import '../logic.dart';
import '../state.dart';

class ChannelTestPageOptimized extends StatelessWidget {
  ChannelTestPageOptimized({super.key});

  final ChannelTestLogic logic = Get.put(ChannelTestLogic());
  final ChannelTestState state = Get.find<ChannelTestLogic>().state;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('频道管理'),
        elevation: 0,
        actions: [
          // 开发者模式切换
          IconButton(
            icon: Icon(
              state.developerMode.value ? Icons.bug_report : Icons.bug_report_outlined,
            ),
            tooltip: '开发者模式',
            onPressed: () => logic.toggleDeveloperMode(),
          ),
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
                case 'settings':
                  _showChannelSettings(context);
                  break;
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'refresh',
                child: Row(
                  children: [
                    Icon(Icons.refresh, size: 18),
                    SizedBox(width: 8),
                    Text('刷新数据'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'clear_cache',
                child: Row(
                  children: [
                    Icon(Icons.delete_outline, size: 18),
                    SizedBox(width: 8),
                    Text('清除缓存'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'check_available',
                child: Row(
                  children: [
                    Icon(Icons.check_circle_outline, size: 18),
                    SizedBox(width: 8),
                    Text('检查可用性'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'settings',
                child: Row(
                  children: [
                    Icon(Icons.settings, size: 18),
                    SizedBox(width: 8),
                    Text('频道设置'),
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

  /// 普通用户视图 - 简洁的频道状态展示
  Widget _buildUserView(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // 频道状态卡片
        _buildChannelStatusCard(context),

        const SizedBox(height: 16),

        // 使用提示
        _buildUsageTips(context),

        const SizedBox(height: 24),

        // 快速操作
        _buildQuickActions(context),
      ],
    );
  }

  /// 频道状态卡片
  Widget _buildChannelStatusCard(BuildContext context) {
    final manager = ChannelManager.instance;
    final channels = manager.allChannelInfo;

    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.dashboard,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Text(
                  '频道状态',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                ),
              ],
            ),
            const Divider(height: 24),
            ...channels.map((info) => _buildChannelStatusItem(context, info)),
          ],
        ),
      ),
    );
  }

  /// 频道状态项
  Widget _buildChannelStatusItem(BuildContext context, ChannelInfo info) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          // 图标
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: info.enabled
                  ? _getChannelColor(info.type).withOpacity(0.1)
                  : Colors.grey.shade100,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              logic.getChannelIcon(info.type),
              color: info.enabled ? _getChannelColor(info.type) : Colors.grey,
            ),
          ),
          const SizedBox(width: 12),
          // 信息
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  info.name,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                ),
                Text(
                  info.description,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Colors.grey[600],
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
    final color = isEnabled ? Colors.green : Colors.grey;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isEnabled ? Icons.check_circle : Icons.block,
            size: 12,
            color: color,
          ),
          const SizedBox(width: 4),
          Text(
            isEnabled ? '已启用' : '已禁用',
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  /// 使用提示
  Widget _buildUsageTips(BuildContext context) {
    return Card(
      color: Theme.of(context).colorScheme.primaryContainer.withOpacity(0.3),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.lightbulb_outline,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Text(
                  '使用提示',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _buildTipItem(context, '在"发现"页面浏览和添加应用'),
            _buildTipItem(context, '点击搜索栏快速搜索特定渠道的应用'),
            _buildTipItem(context, '已添加的应用会显示在"首页"'),
            _buildTipItem(context, '点击右上角图标进入开发者模式'),
          ],
        ),
      ),
    );
  }

  /// 提示项
  Widget _buildTipItem(BuildContext context, String tip) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.arrow_right,
            size: 16,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(width: 8),
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
                fontWeight: FontWeight.bold,
              ),
        ),
        const SizedBox(height: 12),
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
            const SizedBox(width: 12),
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
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          border: Border.all(color: Colors.grey.shade300),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          children: [
            Icon(icon, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 8),
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

  /// 原有的渠道选择器
  Widget _buildChannelSelector(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      color: Theme.of(context).colorScheme.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.developer_mode, size: 16),
              const SizedBox(width: 8),
              Text(
                '开发者模式',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      color: Theme.of(context).colorScheme.primary,
                    ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Obx(() => Wrap(
                spacing: 8,
                runSpacing: 8,
                children: logic.channelList.map((info) {
                  final isSelected = state.selectedChannel.value == info.type;
                  return FilterChip(
                    label: Text(info.name),
                    avatar: Icon(
                      logic.getChannelIcon(info.type),
                      size: 16,
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

  /// 原有的操作面板
  Widget _buildOperationPanel(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      color: Theme.of(context).colorScheme.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '测试操作',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _buildOperationChip(context, 'getAllApps', '获取所有应用'),
              _buildOperationChip(context, 'getAppInfo', '获取应用详情'),
              _buildOperationChip(context, 'searchApps', '搜索应用'),
              _buildOperationChip(context, 'getCategories', '获取分类'),
              _buildOperationChip(context, 'getConfig', '获取配置'),
              _buildOperationChip(context, 'checkUpdate', '检查更新'),
              _buildOperationChip(context, 'doUpdate', '执行更新'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildOperationChip(BuildContext context, String operation, String label) {
    return Obx(() {
      final isSelected = state.currentOperation.value == operation;
      return ActionChip(
        avatar: isSelected
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.play_arrow, size: 16),
        label: Text(label),
        onPressed: isSelected ? null : () => logic.selectOperation(operation),
        backgroundColor: isSelected
            ? Theme.of(context).colorScheme.primaryContainer
            : null,
      );
    });
  }

  /// 原有的结果显示区域
  Widget _buildResultArea(BuildContext context) {
    return Obx(() {
      if (state.result.value.isEmpty) {
        return Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.science_outlined,
                size: 64,
                color: Colors.grey[400],
              ),
              const SizedBox(height: 16),
              Text(
                '选择频道和操作开始测试',
                style: TextStyle(color: Colors.grey[600]),
              ),
            ],
          ),
        );
      }

      return SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: SelectableText(
          state.result.value,
          style: TextStyle(
            fontFamily: 'monospace',
            fontSize: 12,
            color: Theme.of(context).colorScheme.onSurface,
          ),
        ),
      );
    });
  }

  /// 检查可用性
  Future<void> _checkAvailableChannels(BuildContext context) async {
    final available = await ChannelManager.instance.checkAvailableChannels();

    if (context.mounted) {
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('频道可用性'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('可用频道：'),
              const SizedBox(height: 8),
              ...available.map((type) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        const Icon(Icons.check_circle, color: Colors.green, size: 16),
                        const SizedBox(width: 8),
                        Text(logic.getChannelName(type)),
                      ],
                    ),
                  )),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('确定'),
            ),
          ],
        ),
      );
    }
  }

  /// 显示频道设置
  void _showChannelSettings(BuildContext context) {
    Get.toNamed('/channel/settings');
  }

  /// 获取渠道颜色
  Color _getChannelColor(ChannelType type) {
    switch (type) {
      case ChannelType.localDb:
        return Colors.blue;
      case ChannelType.github:
        return Colors.purple;
      case ChannelType.http:
        return Colors.orange;
      case ChannelType.vivo:
        return const Color(0xFF4155D0);
      case ChannelType.fdroid:
        return const Color(0xFF1976D2);
      default:
        return Colors.grey;
    }
  }
}
