import 'package:flutter/material.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/service/install_manager.dart';
import 'package:installed_apps/installed_apps.dart';
import 'package:installed_apps/app_info.dart' as installed;

/// 已安装应用管理页
/// 支持：查看已安装应用、卸载、清理数据/缓存、强制停止
/// 系统应用管理操作需要 Shizuku 授权
class InstalledAppsPage extends StatefulWidget {
  const InstalledAppsPage({super.key});

  @override
  State<InstalledAppsPage> createState() => _InstalledAppsPageState();
}

class _InstalledAppsPageState extends State<InstalledAppsPage> {
  List<installed.AppInfo> _apps = [];
  bool _loading = true;
  String _searchKeyword = '';

  /// Shizuku 是否可用
  bool _shizukuAvailable = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    // 检测 Shizuku 状态
    final manager = InstallManager.instance;
    await manager.checkShizuku();
    if (mounted) {
      setState(() => _shizukuAvailable = manager.isShizukuAvailable);
    }
    await _loadApps();
  }

  Future<void> _loadApps() async {
    setState(() => _loading = true);
    try {
      // 第二个参数 withIcon=true 获取应用图标
      final apps = await InstalledApps.getInstalledApps(true, true);
      if (mounted) {
        setState(() {
          _apps = apps;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('获取已安装应用失败: $e')),
        );
      }
    }
  }

  List<installed.AppInfo> get _filteredApps {
    if (_searchKeyword.isEmpty) return _apps;
    final kw = _searchKeyword.toLowerCase();
    return _apps
        .where((a) =>
            a.name.toLowerCase().contains(kw) ||
            a.packageName.toLowerCase().contains(kw))
        .toList();
  }

  /// 请求 Shizuku 授权
  Future<bool> _ensureShizuku() async {
    final manager = InstallManager.instance;
    if (manager.isShizukuAvailable) return true;

    if (!manager.isBinderRunning) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Shizuku 未运行，请先在 Shizuku 应用中启动')),
        );
      }
      return false;
    }

    final granted = await manager.requestPermission();
    if (mounted) {
      setState(() => _shizukuAvailable = manager.isShizukuAvailable);
    }
    return granted;
  }

  /// 卸载应用
  Future<void> _uninstallApp(installed.AppInfo app) async {
    final confirmed = await _confirmDialog(
      '卸载应用',
      '确定要卸载 ${app.name} 吗？',
      confirmText: '卸载',
      isDestructive: true,
    );
    if (confirmed != true) return;

    // 有 Shizuku 时静默卸载，否则跳系统卸载界面
    if (InstallManager.instance.isShizukuAvailable) {
      final ok = await InstallManager.instance.managePackage(app.packageName, 'uninstall');
      if (ok) {
        _showMessage('已卸载 ${app.name}');
        await _loadApps();
      } else {
        _showMessage('静默卸载失败，将打开系统卸载界面');
        await InstallManager.instance.openUninstallInSystem(app.packageName);
      }
    } else {
      final ok = await InstallManager.instance.openUninstallInSystem(app.packageName);
      if (!ok) {
        _showMessage('无法打开系统卸载界面');
      }
    }
  }

  /// 清理应用数据
  /// 有 Shizuku 时静默清理，否则跳系统应用详情页由用户手动操作
  Future<void> _clearData(installed.AppInfo app) async {
    if (InstallManager.instance.isShizukuAvailable) {
      final confirmed = await _confirmDialog(
        '清理数据',
        '确定要清除 ${app.name} 的所有数据吗？\n这相当于恢复出厂设置（会删除登录状态、本地数据等）。',
        confirmText: '清理',
        isDestructive: true,
      );
      if (confirmed != true) return;
      final ok = await InstallManager.instance.clearAppData(app.packageName);
      _showMessage(ok ? '已清理 ${app.name} 的数据' : '清理数据失败');
    } else {
      // 跳系统应用详情页，用户手动点"清除数据"
      _showMessage('已打开 ${app.name} 的应用详情，请在系统中手动清除数据');
      await InstallManager.instance.openAppDetailsInSystem(app.packageName);
    }
  }

  /// 清理应用缓存
  /// 有 Shizuku 时静默清理，否则/失败时跳系统应用详情页由用户手动操作
  Future<void> _clearCache(installed.AppInfo app) async {
    if (InstallManager.instance.isShizukuAvailable) {
      final ok = await InstallManager.instance.clearAppCache(app.packageName);
      if (ok) {
        _showMessage('已清理 ${app.name} 的缓存');
        return;
      }
      // Shizuku 清理失败，回退系统详情页
    }
    _showMessage('已打开 ${app.name} 的应用详情，请在系统中手动清除缓存');
    await InstallManager.instance.openAppDetailsInSystem(app.packageName);
  }

  /// 强制停止应用
  /// 有 Shizuku 时静默停止，否则跳系统应用详情页
  Future<void> _forceStop(installed.AppInfo app) async {
    if (InstallManager.instance.isShizukuAvailable) {
      final ok = await InstallManager.instance.forceStopApp(app.packageName);
      _showMessage(ok ? '已强制停止 ${app.name}' : '强制停止失败');
    } else {
      _showMessage('已打开 ${app.name} 的应用详情，请在系统中手动停止');
      await InstallManager.instance.openAppDetailsInSystem(app.packageName);
    }
  }

  Future<bool?> _confirmDialog(
    String title,
    String content, {
    String confirmText = '确定',
    bool isDestructive = false,
  }) {
    return AppDialogs.showDialog(
      title: title,
      content: content,
      confirmText: confirmText,
      cancelText: '取消',
      isDangerous: isDestructive,
    );
  }

  void _showMessage(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('已安装应用'),
        actions: [
          IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh),
            onPressed: _loadApps,
          ),
        ],
      ),
      body: Column(
        children: [
          // Shizuku 状态提示
          if (!_shizukuAvailable)
            Container(
              width: double.infinity,
              margin: AppSpacing.onlyHorizontalMD,
              child: Card(
                color: Theme.of(context).colorScheme.secondaryContainer,
                child: ListTile(
                  dense: true,
                  leading: const Icon(Icons.shield_outlined, size: AppTypography.iconMD),
                  title: const Text('Shizuku 未授权'),
                  subtitle: const Text('卸载/清理功能需要 Shizuku 授权'),
                  trailing: TextButton(
                    onPressed: _ensureShizuku,
                    child: const Text('去授权'),
                  ),
                ),
              ),
            )
          else
            Container(
              width: double.infinity,
              margin: AppSpacing.onlyHorizontalMD,
              child: Card(
                color: Theme.of(context).colorScheme.primaryContainer,
                child: ListTile(
                  dense: true,
                  leading: const Icon(Icons.shield, size: AppTypography.iconMD, color: Colors.green),
                  title: const Text('Shizuku 已授权'),
                  subtitle: const Text('可卸载应用、清理数据/缓存'),
                ),
              ),
            ),
          const SizedBox(height: AppSpacing.sm),

          // 搜索框
          Padding(
            padding: AppSpacing.onlyHorizontalMD,
            child: TextField(
              onChanged: (v) => setState(() => _searchKeyword = v),
              decoration: InputDecoration(
                hintText: '搜索已安装应用...',
                prefixIcon: const Icon(Icons.search, size: 20),
                isDense: true,
                filled: true,
                fillColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppRadius.lg),
                  borderSide: BorderSide.none,
                ),
                contentPadding: AppSpacing.onlyHorizontalMD,
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),

          // 应用列表
          Expanded(
            child: _loading
                ? const Center(child: AppLoading(size: AppLoadingSize.medium))
                : _filteredApps.isEmpty
                    ? const Center(child: Text('未找到已安装应用'))
                    : ListView.builder(
                        padding: AppSpacing.onlyHorizontalMD,
                        itemCount: _filteredApps.length,
                        itemBuilder: (context, index) {
                          final app = _filteredApps[index];
                          return _buildAppTile(context, app);
                        },
                      ),
          ),
        ],
      ),
    );
  }

  Widget _buildAppTile(BuildContext context, installed.AppInfo app) {
    return Card(
      margin: EdgeInsets.only(bottom: AppSpacing.sm),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
        side: BorderSide(
          color: Theme.of(context).colorScheme.outlineVariant.withOpacity(0.5),
        ),
      ),
      child: ListTile(
        leading: app.icon != null && app.icon!.isNotEmpty
            ? ClipRRect(
                borderRadius: BorderRadius.circular(AppRadius.sm),
                child: Image.memory(app.icon!, width: 40, height: 40),
              )
            : CircleAvatar(
                radius: 20,
                child: Icon(Icons.android, size: AppTypography.iconMD),
              ),
        title: Text(
          app.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                fontWeight: AppTypography.weightMedium,
              ),
        ),
        subtitle: Text(
          '${app.packageName}\n版本: ${app.versionName}',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: AppColors.textSecondary,
              ),
        ),
        isThreeLine: true,
        trailing: PopupMenuButton<String>(
          icon: const Icon(Icons.more_vert, size: AppTypography.iconSM),
          onSelected: (value) {
            switch (value) {
              case 'uninstall':
                _uninstallApp(app);
                break;
              case 'clear_data':
                _clearData(app);
                break;
              case 'clear_cache':
                _clearCache(app);
                break;
              case 'force_stop':
                _forceStop(app);
                break;
            }
          },
          itemBuilder: (context) => [
            const PopupMenuItem(
              value: 'uninstall',
              child: Row(
                children: [
                  Icon(Icons.delete_outline, color: AppColors.error, size: 18),
                  SizedBox(width: AppSpacing.sm),
                  Text('卸载应用'),
                ],
              ),
            ),
            const PopupMenuItem(
              value: 'clear_data',
              child: Row(
                children: [
                  Icon(Icons.restart_alt, color: Colors.orange, size: 18),
                  SizedBox(width: AppSpacing.sm),
                  Text('清理数据'),
                ],
              ),
            ),
            const PopupMenuItem(
              value: 'clear_cache',
              child: Row(
                children: [
                  Icon(Icons.cleaning_services, color: Colors.teal, size: 18),
                  SizedBox(width: AppSpacing.sm),
                  Text('清理缓存'),
                ],
              ),
            ),
            const PopupMenuItem(
              value: 'force_stop',
              child: Row(
                children: [
                  Icon(Icons.stop_circle_outlined, color: Colors.blueGrey, size: 18),
                  SizedBox(width: AppSpacing.sm),
                  Text('强制停止'),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
