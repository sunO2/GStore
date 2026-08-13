import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:gstore/core/config/config_manager.dart';
import 'package:gstore/core/config/providers/download_config_provider.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/theme/theme_controller.dart';
import 'package:gstore/http/download/DownloadStatus.dart';

/// GitHub 代理预设地址
const List<String> presetProxyHosts = [
  'https://gh-proxy.org/',
  'https://v4.gh-proxy.org/',
  'https://v6.gh-proxy.org/',
  'https://cdn.gh-proxy.org/',
  'https://axisnow.gh-proxy.org/',
];

/// Main settings page with appearance and other settings
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('设置'),
      ),
      body: ListView(
        children: [
          // Appearance section
          _buildSectionHeader('外观'),
          _buildAppearanceSection(context),
          const SizedBox(height: AppSpacing.xxl),

          // Data & Sync section
          _buildSectionHeader('数据与同步'),
          _buildDataSyncSection(context),
          const SizedBox(height: AppSpacing.xxl),

          // Install & Permission section
          _buildSectionHeader('安装与权限'),
          _buildInstallSection(context),
          const SizedBox(height: AppSpacing.xxl),

          // Download section
          _buildSectionHeader('下载'),
          _buildDownloadSection(context),
          const SizedBox(height: AppSpacing.xxl),

          // About section
          _buildSectionHeader('关于'),
          _buildAboutSection(context),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: AppSpacing.onlyHorizontalLG,
      child: Text(
        title,
        style: TextStyle(
          fontSize: AppTypography.sizeSM,
          fontWeight: AppTypography.weightMedium,
          color: Colors.grey,
        ),
      ),
    );
  }

  Widget _buildAppearanceSection(BuildContext context) {
    return Card(
      margin: AppSpacing.allLG,
      child: Column(
        children: [
          ListTile(
            leading: const Icon(Icons.palette_outlined),
            title: const Text('主题'),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Obx(() {
                  final controller = Get.find<ThemeController>();
                  return Text(
                    controller.themeMode.displayName,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.primary,
                      fontWeight: AppTypography.weightMedium,
                    ),
                  );
                }),
                const Icon(Icons.chevron_right),
              ],
            ),
            onTap: () => Get.toNamed(AppRoute.themeSettings),
          ),
        ],
      ),
    );
  }

  Widget _buildDataSyncSection(BuildContext context) {
    return Card(
      margin: AppSpacing.allLG,
      child: Column(
        children: [
          ListTile(
            leading: const Icon(Icons.source, size: AppTypography.iconMD),
            title: const Text('F-Droid 源管理'),
            trailing:
                const Icon(Icons.chevron_right, size: AppTypography.iconSM),
            onTap: () => Get.toNamed(AppRoute.fdroidRepo),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.backup, size: AppTypography.iconMD),
            title: const Text('数据备份'),
            trailing:
                const Icon(Icons.chevron_right, size: AppTypography.iconSM),
            onTap: () => Get.toNamed(AppRoute.backup),
          ),
          const Divider(height: 1),
          // GitHub 代理设置
          ListTile(
            leading: const Icon(Icons.cloud, size: AppTypography.iconMD),
            title: const Text('GitHub 代理'),
            subtitle: Text(
              '当前: ${getProxy().isEmpty ? '未设置' : getProxy()}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing:
                const Icon(Icons.chevron_right, size: AppTypography.iconSM),
            onTap: () => _showProxySettingDialog(context),
          ),
        ],
      ),
    );
  }

  /// 预设代理链接 span：逗号分隔，选中项前加 ✅ 并高亮（点击选中并生效）
  TextSpan _buildProxyLinkSpan(
    BuildContext context, {
    required String host,
    required bool isFirst,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final text = '${isFirst ? '' : ', '}${isSelected ? '✅ ' : ''}$host';
    return TextSpan(
      text: text,
      style: TextStyle(
        // 选中：主题色加粗；未选中：onSurfaceVariant 淡化（提示可点击）
        color: isSelected ? scheme.primary : scheme.onSurfaceVariant,
        fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
        decoration: isSelected ? null : TextDecoration.underline,
        decorationColor: scheme.outlineVariant,
      ),
      recognizer: TapGestureRecognizer()..onTap = onTap,
    );
  }

  /// 显示 GitHub 代理设置对话框
  Future<void> _showProxySettingDialog(BuildContext context) async {
    final controller = TextEditingController(text: getProxy());
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('GitHub 代理设置'),
        content: StatefulBuilder(
          builder: (context, setDialogState) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('设置 GitHub 相关下载的代理前缀，用于加速国内访问。'),
              const SizedBox(height: AppSpacing.md),
              // 预设代理快速选择：富文本多链接逗号分隔，
              // 点击某个链接即选中并立即生效（当前项前显示 ✅）
              Text.rich(
                TextSpan(
                  children: [
                    for (var i = 0; i < presetProxyHosts.length; i++)
                      _buildProxyLinkSpan(
                        context,
                        host: presetProxyHosts[i],
                        isFirst: i == 0,
                        isSelected: controller.text == presetProxyHosts[i],
                        onTap: () {
                          controller.text = presetProxyHosts[i];
                          // 点击即生效（无需再点保存）
                          updateProxy(presetProxyHosts[i]);
                          setDialogState(() {});
                        },
                      ),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              TextField(
                controller: controller,
                decoration: const InputDecoration(
                  labelText: '代理前缀',
                  hintText: 'https://gh-proxy.org/',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              const Text(
                '设置了代理则下载走代理；留空表示不使用代理',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );

    if (result != null) {
      var value = result;
      // 确保以 / 结尾（空字符串表示不使用代理）
      if (value.isNotEmpty && !value.endsWith('/')) {
        value = '$value/';
      }
      updateProxy(value.isNotEmpty ? value : null);
      if (mounted)
        setState(() {}); // 刷新代理 subtitle（StatelessWidget → StatefulWidget）
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(value.isEmpty ? '已禁用 GitHub 代理' : '代理已更新: $value')),
        );
      }
    }
  }

  Widget _buildInstallSection(BuildContext context) {
    return Card(
      margin: AppSpacing.allLG,
      child: Column(
        children: [
          // Shizuku 授权状态
          _ShizukuTile(),
          const Divider(height: 1),
          // 安装方式提示
          ListTile(
            leading:
                const Icon(Icons.system_update_alt, size: AppTypography.iconMD),
            title: const Text('安装方式'),
            subtitle: const Text('开启 Shizuku 后可静默安装应用，无需逐次确认；未授权时使用系统安装'),
            isThreeLine: true,
          ),
        ],
      ),
    );
  }

  Widget _buildDownloadSection(BuildContext context) {
    return Card(
      margin: AppSpacing.allLG,
      child: Column(
        children: [
          // 多段下载开关
          const _MultiSegmentDownloadTile(),
        ],
      ),
    );
  }

  Widget _buildAboutSection(BuildContext context) {
    return Card(
      margin: AppSpacing.allLG,
      child: Column(
        children: [
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('版本'),
            subtitle: const Text('1.0.19'),
          ),
          const Divider(height: 1),
          // 数据库更新（放在版本下面）
          const _DataUpdateTile(),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.description_outlined),
            title: const Text('开源协议'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              // TODO: Show license information
            },
          ),
        ],
      ),
    );
  }
}

/// 数据更新检测 Tile
/// 状态：可检查（箭头）/ 检查中（loading）/ 有更新（"更新"按钮）
class _DataUpdateTile extends StatefulWidget {
  const _DataUpdateTile();

  @override
  State<_DataUpdateTile> createState() => _DataUpdateTileState();
}

class _DataUpdateTileState extends State<_DataUpdateTile> {
  /// 是否正在检查
  bool _checking = false;

  /// 是否有更新
  bool _hasUpdate = false;

  /// 是否正在下载更新
  bool _downloading = false;

  /// 当前数据库版本
  String _currentVersion = '0.0.0.0';

  /// 可更新版本
  String? _latestVersion;

  @override
  void initState() {
    super.initState();
    _loadCurrentVersion();
  }

  /// 读取当前数据库版本
  Future<void> _loadCurrentVersion() async {
    try {
      final version = await Get.find<DbManager>().getDBVersion('gstore');
      if (mounted) {
        setState(() => _currentVersion = version);
      }
    } catch (e) {
      appLog.error('_DataUpdateTile: 读取当前版本失败 - $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final Widget trailing;
    if (_checking || _downloading) {
      // 与刷新按钮同尺寸容器居中，避免交替时跳动
      trailing = const SizedBox(
        width: 40,
        height: 40,
        child: Center(
          child: AppLoading(size: AppLoadingSize.small),
        ),
      );
    } else if (_hasUpdate) {
      // 有更新：显示"更新"按钮
      trailing = FilledButton.tonal(
        onPressed: _performUpdate,
        style: FilledButton.styleFrom(
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.symmetric(horizontal: 12),
        ),
        child: const Text('更新'),
      );
    } else {
      // 默认：双箭头刷新按钮（检查更新），固定在 40x40 容器内与 loading 对齐
      trailing = SizedBox(
        width: 40,
        height: 40,
        child: IconButton(
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(),
          icon: const Icon(Icons.sync, size: AppTypography.iconMD),
          tooltip: '检查更新',
          onPressed: _checkForUpdate,
        ),
      );
    }

    return ListTile(
      leading: Obx(() {
        final hasDbUpdate = BadgeService.instance.hasBadge(BadgeKey.dbUpdate);
        return AppBadge(
          count: hasDbUpdate ? 1 : 0,
          showCount: false,
          child:
              const Icon(Icons.system_update_alt, size: AppTypography.iconMD),
        );
      }),
      title: Text(_downloading ? '正在更新数据库...' : '数据库更新'),
      subtitle: Text(
        _hasUpdate && _latestVersion != null
            ? '当前 $_currentVersion → 可更新 $_latestVersion'
            : '当前版本: $_currentVersion',
      ),
      trailing: trailing,
      onTap: _checking || _downloading ? null : _checkForUpdate,
    );
  }

  /// 检查是否有更新（不自动下载）
  Future<void> _checkForUpdate() async {
    if (_checking) return;
    setState(() {
      _checking = true;
      _hasUpdate = false;
    });

    try {
      final info = await Get.find<DbManager>().checkUpdateInfo('gstore');
      if (!mounted) return;
      setState(() {
        _checking = false;
        _hasUpdate = info != null;
        _latestVersion = info?['latest'];
        if (info != null) _currentVersion = info['current']!;
      });
      if (info == null) {
        Get.snackbar(
          '已是最新',
          '本地数据库已是最新版本',
          snackPosition: SnackPosition.BOTTOM,
          duration: const Duration(seconds: 2),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _checking = false);
        Get.snackbar(
          '检查失败',
          '检查更新出错: $e',
          snackPosition: SnackPosition.BOTTOM,
          backgroundColor: Get.theme.colorScheme.errorContainer,
          duration: const Duration(seconds: 3),
        );
      }
    }
  }

  /// 执行更新下载
  Future<void> _performUpdate() async {
    if (_downloading) return;
    setState(() => _downloading = true);

    try {
      final result = await "gstore".checkUpdate();
      if (!mounted) return;
      setState(() {
        _downloading = false;
        _hasUpdate = false;
      });
      if (result == DownloadStatus.DOWNLOAD_SUCCESS) {
        await _loadCurrentVersion();
        setState(() => _latestVersion = null);
        Get.snackbar(
          '更新成功',
          '本地数据库已更新',
          snackPosition: SnackPosition.BOTTOM,
          duration: const Duration(seconds: 2),
        );
      } else {
        Get.snackbar(
          '更新失败',
          '数据库更新失败，请检查网络或代理设置',
          snackPosition: SnackPosition.BOTTOM,
          backgroundColor: Get.theme.colorScheme.errorContainer,
          duration: const Duration(seconds: 3),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _downloading = false);
        Get.snackbar(
          '更新失败',
          '更新出错: $e',
          snackPosition: SnackPosition.BOTTOM,
          backgroundColor: Get.theme.colorScheme.errorContainer,
          duration: const Duration(seconds: 3),
        );
      }
    }
  }
}

/// Shizuku 授权状态 Tile
class _ShizukuTile extends StatefulWidget {
  @override
  State<_ShizukuTile> createState() => _ShizukuTileState();
}

class _ShizukuTileState extends State<_ShizukuTile> {
  bool _checking = true;
  bool _available = false;
  bool _granted = false;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    final manager = InstallManager.instance;
    await manager.checkShizuku();
    if (mounted) {
      setState(() {
        _checking = false;
        _available = manager.isBinderRunning;
        _granted = manager.isPermissionGranted;
      });
    }
  }

  Future<void> _requestPermission() async {
    setState(() => _checking = true);
    final manager = InstallManager.instance;
    final granted = await manager.requestPermission();
    if (mounted) {
      setState(() {
        _checking = false;
        _available = manager.isBinderRunning;
        _granted = granted;
      });
    }
    if (mounted && granted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Shizuku 授权成功，可静默安装应用')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_checking) {
      return const ListTile(
        leading: Icon(Icons.shield_outlined, size: AppTypography.iconMD),
        title: Text('Shizuku 状态'),
        subtitle: Text('检测中...'),
      );
    }

    if (!_available) {
      return ListTile(
        leading: const Icon(Icons.shield_outlined, size: AppTypography.iconMD),
        title: const Text('Shizuku 状态'),
        subtitle: const Text('未运行（需安装 Shizuku 并启动）'),
        trailing: TextButton(
          onPressed: () async {
            final manager = InstallManager.instance;
            await manager.checkShizuku();
            if (mounted)
              setState(() {
                _available = manager.isBinderRunning;
                _granted = manager.isPermissionGranted;
              });
          },
          child: const Text('重新检测'),
        ),
      );
    }

    if (!_granted) {
      return ListTile(
        leading: const Icon(Icons.shield_outlined, size: AppTypography.iconMD),
        title: const Text('Shizuku 状态'),
        subtitle: const Text('已运行，未授权'),
        trailing: TextButton(
          onPressed: _requestPermission,
          child: const Text('授权'),
        ),
      );
    }

    return const ListTile(
      leading:
          Icon(Icons.shield, size: AppTypography.iconMD, color: Colors.green),
      title: Text('Shizuku 状态'),
      subtitle: Text('已授权，可静默安装'),
    );
  }
}

/// 多段下载开关 Tile
///
/// 控制是否启用多段并行下载（自适应分段，可显著加速大文件下载）。
/// 弱网/网络不稳定时可关闭，回退为单连接下载。
class _MultiSegmentDownloadTile extends StatefulWidget {
  const _MultiSegmentDownloadTile();

  @override
  State<_MultiSegmentDownloadTile> createState() =>
      _MultiSegmentDownloadTileState();
}

class _MultiSegmentDownloadTileState extends State<_MultiSegmentDownloadTile> {
  bool _enabled = true;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final provider = ConfigManager.instance.providers['download_config'];
      if (provider is DownloadConfigProvider) {
        final enabled = await provider.isMultiSegmentEnabled();
        if (mounted) {
          setState(() {
            _enabled = enabled;
            _loaded = true;
          });
        }
        return;
      }
    } catch (e) {
      debugPrint('SettingsPage: 读取多段下载配置失败 - $e');
    }
    if (mounted) {
      setState(() {
        _enabled = true;
        _loaded = true;
      });
    }
  }

  Future<void> _toggle(bool value) async {
    setState(() => _enabled = value);
    try {
      final provider = ConfigManager.instance.providers['download_config'];
      if (provider is DownloadConfigProvider) {
        await provider.setMultiSegmentEnabled(value);
        appLog.info('SettingsPage: 多段下载已${value ? "开启" : "关闭"}');
      }
    } catch (e) {
      debugPrint('SettingsPage: 保存多段下载配置失败 - $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      secondary: Icon(
        Icons.multiple_stop,
        size: AppTypography.iconMD,
        color: Theme.of(context).colorScheme.primary,
      ),
      title: const Text('多段下载'),
      subtitle: const Text('自适应分段并行下载（最大 8 段），大文件下载更快。弱网或不稳定时可关闭'),
      value: _enabled,
      onChanged: _loaded ? _toggle : null,
    );
  }
}
