import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:gstore/core/core.dart';

import 'logic.dart';
import 'state.dart';

class WebDavConfigPage extends StatelessWidget {
  const WebDavConfigPage({super.key});

  @override
  Widget build(BuildContext context) {
    final logic = Get.put(WebDavConfigLogic());
    final state = logic.state;

    return Scaffold(
      appBar: AppBar(
        title: const Text('WebDAV 配置'),
        actions: [
          Obx(() {
            final hasConfig = state.hasConfig.value;
            if (hasConfig) {
              IconButton(
                icon: const Icon(Icons.delete_outline),
                onPressed: () => _confirmDeleteConfig(context, logic),
                tooltip: '删除配置',
              );
            }
            return const SizedBox.shrink();
          }),
        ],
      ),
      body: ListView(
        padding: AppSpacing.allLG,
        children: [
          // 说明卡片
          _buildInfoCard(context),

          const SizedBox(height: AppSpacing.lg),

          // 配置表单
          _buildConfigForm(context, logic, state),

          const SizedBox(height: AppSpacing.xl),

          // 测试连接按钮
          _buildTestButton(context, logic, state),

          const SizedBox(height: AppSpacing.lg),

          // 保存按钮
          _buildSaveButton(context, logic, state),
        ],
      ),
    );
  }

  /// 说明卡片
  Widget _buildInfoCard(BuildContext context) {
    return AppCard(
      padding: AppSpacing.allLG,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.cloud_outlined,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(width: AppSpacing.sm),
              Text(
                '什么是 WebDAV？',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          Text(
            'WebDAV 是一种基于 HTTP 协议的文件共享协议。你可以将备份数据上传到支持 WebDAV 的网盘服务，实现云端备份和同步。',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: AppColors.textSecondary,
                ),
          ),
          const SizedBox(height: AppSpacing.md),
          Text(
            '支持的网盘：坚果云、Dropbox、Nextcloud、ownCloud 等',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: AppColors.textTertiary,
                ),
          ),
        ],
      ),
    );
  }

  /// 配置表单
  Widget _buildConfigForm(
    BuildContext context,
    WebDavConfigLogic logic,
    WebDavConfigState state,
  ) {
    return AppCard(
      padding: AppSpacing.allLG,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '服务器配置',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: AppSpacing.lg),

          // 服务器地址
          TextField(
            controller: state.urlController,
            decoration: const InputDecoration(
              labelText: '服务器地址',
              hintText: 'example.com/dav',
              prefixIcon: Icon(Icons.dns),
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: AppSpacing.md),

          // 用户名
          TextField(
            controller: state.usernameController,
            decoration: const InputDecoration(
              labelText: '用户名',
              hintText: '请输入用户名',
              prefixIcon: Icon(Icons.person),
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: AppSpacing.md),

          // 密码
          Obx(() => TextField(
                controller: state.passwordController,
                obscureText: state.obscurePassword.value,
                decoration: InputDecoration(
                  labelText: '密码',
                  hintText: '请输入密码',
                  prefixIcon: const Icon(Icons.lock),
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    icon: Icon(
                      state.obscurePassword.value
                          ? Icons.visibility_off
                          : Icons.visibility,
                    ),
                    onPressed: () {
                      state.obscurePassword.value =
                          !state.obscurePassword.value;
                    },
                  ),
                ),
              )),
          const SizedBox(height: AppSpacing.md),

          // 备份路径
          TextField(
            controller: state.backupPathController,
            decoration: const InputDecoration(
              labelText: '备份路径',
              hintText: '/GStore',
              prefixIcon: Icon(Icons.folder),
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: AppSpacing.lg),

          // HTTPS 开关
          Obx(() => SwitchListTile(
                title: const Text('启用 HTTPS'),
                subtitle: const Text('使用加密连接传输数据'),
                value: state.enableHttps.value,
                onChanged: (value) {
                  state.enableHttps.value = value;
                },
              )),
        ],
      ),
    );
  }

  /// 测试连接按钮
  Widget _buildTestButton(
    BuildContext context,
    WebDavConfigLogic logic,
    WebDavConfigState state,
  ) {
    return Obx(() => SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: state.isTesting.value
                ? null
                : () => logic.testConnection(),
            icon: state.isTesting.value
                ? const AppLoading(size: AppLoadingSize.small)
                : const Icon(Icons.wifi_find),
            label: Text(state.isTesting.value ? '测试中...' : '测试连接'),
          ),
        ));
  }

  /// 保存按钮
  Widget _buildSaveButton(
    BuildContext context,
    WebDavConfigLogic logic,
    WebDavConfigState state,
  ) {
    return Obx(() => SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: state.isSaving.value
                ? null
                : () => logic.saveConfig(context),
            icon: state.isSaving.value
                ? const AppLoading(size: AppLoadingSize.small)
                : const Icon(Icons.save),
            label: Text(state.isSaving.value ? '保存中...' : '保存配置'),
          ),
        ));
  }

  /// 确认删除配置
  void _confirmDeleteConfig(
    BuildContext context,
    WebDavConfigLogic logic,
  ) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除配置'),
        content: const Text('确定要删除 WebDAV 配置吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(context);
              logic.deleteConfig();
            },
            child: const Text('删除'),
          ),
        ],
      ),
    );
  }
}
