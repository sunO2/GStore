import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:gstore/core/channel/channel.dart';
import 'package:gstore/core/icons/Icons.dart';

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
        title: const Text('Channel 测试'),
        elevation: 0,
        actions: [
          Obx(() => IconButton(
                onPressed: state.isQuerying.value ? null : logic.refresh,
                icon: state.isQuerying.value
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh),
              )),
          PopupMenuButton<String>(
            onSelected: (value) async {
              switch (value) {
                case 'clear_cache':
                  await logic.clearCache();
                  break;
                case 'check_available':
                  _checkAvailableChannels(context);
                  break;
              }
            },
            itemBuilder: (context) => [
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
            ],
          ),
        ],
      ),
      body: Column(
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
      ),
    );
  }

  /// 渠道选择器
  Widget _buildChannelSelector(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      color: Theme.of(context).colorScheme.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '选择渠道',
            style: Theme.of(context).textTheme.titleSmall,
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

  /// 操作面板
  Widget _buildOperationPanel(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      color: Theme.of(context).colorScheme.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '操作',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
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
            ? const Icon(Icons.check, size: 16)
            : const Icon(Icons.play_arrow, size: 16),
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
            padding: const EdgeInsets.only(top: 12),
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
            padding: const EdgeInsets.only(top: 12),
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
            padding: const EdgeInsets.only(top: 12),
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
        return const Center(
          child: CircularProgressIndicator(),
        );
      }

      if (state.errorMessage.value.isNotEmpty) {
        return Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.error_outline,
                size: 48,
                color: Colors.red,
              ),
              const SizedBox(height: 16),
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
                size: 48,
                color: Theme.of(context).colorScheme.primary.withOpacity(0.5),
              ),
              const SizedBox(height: 16),
              Text(
                '选择操作并执行查询',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Colors.grey,
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
      padding: const EdgeInsets.all(12),
      color: Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.3),
      child: Row(
        children: [
          Icon(
            result.success ? Icons.check_circle : Icons.error,
            size: 16,
            color: result.success ? Colors.green : Colors.red,
          ),
          const SizedBox(width: 8),
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
          padding: const EdgeInsets.all(16),
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
              size: 48,
              color: result.data == true ? Colors.orange : Colors.green,
            ),
            const SizedBox(height: 16),
            Text(
              result.data == true ? '有新版本可用' : '已是最新版本',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (result.metadata?['currentVersion'] != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
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
                color: Colors.grey,
              ),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(8),
      itemCount: state.apps.length,
      itemBuilder: (context, index) {
        final app = state.apps[index];
        return Card(
          margin: const EdgeInsets.only(bottom: 8),
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
                style: const TextStyle(fontSize: 10),
              ),
              visualDensity: VisualDensity.compact,
            ),
          ),
        );
      },
    );
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
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      const Icon(Icons.check_circle, color: Colors.green, size: 16),
                      const SizedBox(width: 8),
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
