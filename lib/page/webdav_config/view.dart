import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/webdav/webdav_config.dart';

import 'providers.dart';

class WebDavConfigPage extends ConsumerStatefulWidget {
  const WebDavConfigPage({super.key});

  @override
  ConsumerState<WebDavConfigPage> createState() => _WebDavConfigPageState();
}

class _WebDavConfigPageState extends ConsumerState<WebDavConfigPage> {
  final TextEditingController _urlController = TextEditingController();
  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _backupPathController =
      TextEditingController(text: '/GStore');

  @override
  void initState() {
    super.initState();
    _loadExistingConfig();
  }

  @override
  void dispose() {
    _urlController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _backupPathController.dispose();
    super.dispose();
  }

  /// 回填已保存的配置。
  Future<void> _loadExistingConfig() async {
    final config = await WebDavConfigManager.instance.loadConfig();
    if (!mounted) return;
    if (config != null) {
      _urlController.text = config.url;
      _usernameController.text = config.username;
      _passwordController.text = config.password;
      _backupPathController.text = config.backupPath;
      ref.read(webDavConfigProvider.notifier).setEnableHttps(config.enableHttps);
    }
    await ref.read(webDavConfigProvider.notifier).loadHasConfig();
  }

  WebDavConfig _configFromInput() {
    final ui = ref.read(webDavConfigProvider);
    return WebDavConfig(
      url: _urlController.text.trim(),
      username: _usernameController.text.trim(),
      password: _passwordController.text,
      backupPath: _backupPathController.text.trim(),
      enableHttps: ui.enableHttps,
    );
  }

  @override
  Widget build(BuildContext context) {
    final ui = ref.watch(webDavConfigProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('WebDAV 配置'),
        actions: [
          if (ui.hasConfig)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              onPressed: () => _confirmDeleteConfig(context),
              tooltip: '删除配置',
            ),
        ],
      ),
      body: ListView(
        padding: AppSpacing.allLG,
        children: [
          _buildInfoCard(context),

          const SizedBox(height: AppSpacing.lg),

          _buildConfigForm(context, ui),

          const SizedBox(height: AppSpacing.xl),

          _buildTestButton(context, ui),

          const SizedBox(height: AppSpacing.lg),

          _buildSaveButton(context, ui),
        ],
      ),
    );
  }

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
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
          const SizedBox(height: AppSpacing.md),
          Text(
            '支持的网盘：坚果云、Dropbox、Nextcloud、ownCloud 等',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.outline,
                ),
          ),
        ],
      ),
    );
  }

  Widget _buildConfigForm(BuildContext context, WebDavConfigUiState ui) {
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

          TextField(
            controller: _urlController,
            decoration: const InputDecoration(
              labelText: '服务器地址',
              hintText: 'example.com/dav',
              prefixIcon: Icon(Icons.dns),
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: AppSpacing.md),

          TextField(
            controller: _usernameController,
            decoration: const InputDecoration(
              labelText: '用户名',
              hintText: '请输入用户名',
              prefixIcon: Icon(Icons.person),
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: AppSpacing.md),

          TextField(
            controller: _passwordController,
            obscureText: ui.obscurePassword,
            decoration: InputDecoration(
              labelText: '密码',
              hintText: '请输入密码',
              prefixIcon: const Icon(Icons.lock),
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                icon: Icon(
                  ui.obscurePassword ? Icons.visibility_off : Icons.visibility,
                ),
                onPressed: () => ref
                    .read(webDavConfigProvider.notifier)
                    .toggleObscurePassword(),
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.md),

          TextField(
            controller: _backupPathController,
            decoration: const InputDecoration(
              labelText: '备份路径',
              hintText: '/GStore',
              prefixIcon: Icon(Icons.folder),
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: AppSpacing.lg),

          SwitchListTile(
            title: const Text('启用 HTTPS'),
            subtitle: const Text('使用加密连接传输数据'),
            value: ui.enableHttps,
            onChanged: (value) =>
                ref.read(webDavConfigProvider.notifier).setEnableHttps(value),
          ),
        ],
      ),
    );
  }

  Widget _buildTestButton(BuildContext context, WebDavConfigUiState ui) {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed:
            ui.isTesting ? null : () => _runTestConnection(),
        icon: ui.isTesting
            ? const AppLoading(size: AppLoadingSize.small)
            : const Icon(Icons.wifi_find),
        label: Text(ui.isTesting ? '测试中...' : '测试连接'),
      ),
    );
  }

  Widget _buildSaveButton(BuildContext context, WebDavConfigUiState ui) {
    return SizedBox(
      width: double.infinity,
      child: FilledButton.icon(
        onPressed: ui.isSaving ? null : () => _runSave(),
        icon: ui.isSaving
            ? const AppLoading(size: AppLoadingSize.small)
            : const Icon(Icons.save),
        label: Text(ui.isSaving ? '保存中...' : '保存配置'),
      ),
    );
  }

  Future<void> _runTestConnection() async {
    await ref.read(webDavConfigProvider.notifier).testConnection(_configFromInput());
  }

  Future<void> _runSave() async {
    final ok = await ref.read(webDavConfigProvider.notifier).save(_configFromInput());
    if (ok && mounted) Navigator.pop(context, true);
  }

  Future<void> _confirmDeleteConfig(BuildContext context) async {
    final confirmed = await AppDialogs.showDialog(
      title: '删除配置',
      content: '确定要删除 WebDAV 配置吗？',
      confirmText: '删除',
      cancelText: '取消',
      isDangerous: true,
    );
    if (confirmed == true && mounted) {
      await ref.read(webDavConfigProvider.notifier).delete();
    }
  }
}
