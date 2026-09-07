/// F-Droid 仓库管理页面业务逻辑
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gstore/core/design/design_tokens.dart';
import 'package:gstore/core/fdroid/FdroidRepoManager.dart';
import 'package:gstore/core/fdroid/FdroidRepoModels.dart';
import 'package:gstore/core/logger/LogManager.dart';
import 'package:gstore/core/module/interfaces/service_interfaces.dart';
import 'package:gstore/core/module/module_manager.dart';
import 'package:gstore/page/fdroid_repo/state.dart';

/// F-Droid 仓库管理业务逻辑（Riverpod 版）。
class FdroidRepoNotifier extends Notifier<FdroidRepoState> {
  final TextEditingController searchController = TextEditingController();

  /// F-Droid 仓库服务（注册表注入：fdroid 模块下线时为 null → 软降级）
  IFdroidRepoService? get _service =>
      ModuleManager.instance.get<IFdroidRepoService>();

  /// 具体管理器（绑定实现为 FdroidRepoManager 时可用，承载响应式源/进度状态）
  FdroidRepoManager? get _manager =>
      _service is FdroidRepoManager ? _service as FdroidRepoManager : null;

  /// 是否已执行过 [start]（防止重复初始化）
  bool _started = false;

  @override
  FdroidRepoState build() {
    final manager = _manager;
    if (manager == null) {
      // fdroid 模块未启用 → 页面降级为空状态提示
      return const FdroidRepoState(errorMessage: 'F-Droid 模块未启用');
    }
    // 订阅管理器响应式字段（源列表/加载进度/错误信息等）同步到页面状态
    manager.addListener(_syncFromManager);
    ref.onDispose(() {
      manager.removeListener(_syncFromManager);
      searchController.dispose();
    });
    return FdroidRepoState(
      sources: List.of(manager.sources),
      currentSource: manager.currentSource,
      isLoading: manager.isLoading,
      loadingProgress: manager.loadingProgress * 100,
      errorMessage: manager.errorMessage?.isNotEmpty == true
          ? manager.errorMessage
          : null,
    );
  }

  /// 页面挂载后初始化（view initState 调用，等价原 GetX onInit）。
  /// 幂等：重复调用自动跳过（模块重新启用后可再次触发初始化）。
  Future<void> start() async {
    if (_started) return;
    _started = true;
    await _initData();
  }

  /// 将管理器的响应式字段同步到页面状态。
  void _syncFromManager() {
    final manager = _manager;
    if (manager == null) return;
    final error = manager.errorMessage;
    state = state.copyWith(
      sources: List.of(manager.sources),
      currentSource: manager.currentSource,
      isLoading: manager.isLoading,
      loadingProgress: manager.loadingProgress * 100,
      errorMessage: error?.isNotEmpty == true ? error : null,
    );
  }

  /// 初始化数据
  Future<void> _initData() async {
    final manager = _manager;
    if (manager == null) {
      state = state.copyWith(errorMessage: 'F-Droid 模块未启用');
      return;
    }
    // 首帧后管理器字段已就绪，先同步一次
    _syncFromManager();
    try {
      // 加载统计信息
      await _loadStatistics();

      // 检查更新
      await _checkUpdate();
    } catch (e) {
      state = state.copyWith(errorMessage: '初始化失败: $e');
    }
  }

  /// 加载统计信息
  Future<void> _loadStatistics() async {
    final manager = _manager;
    if (manager == null) return;
    try {
      state = state.copyWith(statistics: await manager.getStatistics());
    } catch (e) {
      appLog.error('加载统计信息失败: $e');
    }
  }

  /// 检查更新
  Future<void> _checkUpdate() async {
    final manager = _manager;
    if (manager == null) return;
    try {
      final result = await manager.checkIncrementalUpdate();
      if (result == null) return; // Rust 实现暂不支持增量更新
      state = state.copyWith(
        hasUpdate: result['hasUpdate'] ?? false,
        currentVersion: result['currentVersion'] ?? 0,
        latestVersion: result['latestVersion'] ?? 0,
      );
    } catch (e) {
      appLog.error('检查更新失败: $e');
    }
  }

  /// 加载仓库数据
  Future<void> loadRepository() async {
    final service = _service;
    final manager = _manager;
    if (service == null) {
      AppDialogs.showError('F-Droid 模块未启用');
      return;
    }
    debugPrint('FdroidRepoNotifier: loadRepository 被调用');
    debugPrint('FdroidRepoNotifier: state.currentSource = ${state.currentSource}');
    debugPrint('FdroidRepoNotifier: _manager.currentSource = ${manager?.currentSource}');

    if (state.currentSource == null) {
      debugPrint('FdroidRepoNotifier: currentSource 为 null，尝试从 manager 同步');
      state = state.copyWith(currentSource: manager?.currentSource);
    }

    if (state.currentSource == null) {
      AppDialogs.showError('请先选择一个源');
      return;
    }

    try {
      appLog.info('FdroidRepoNotifier: 开始加载仓库: ${state.currentSource?.repoUrl}');
      await service.loadRepository();

      await _loadStatistics();
      AppDialogs.showSuccess('仓库数据加载完成');
    } catch (e) {
      appLog.error('FdroidRepoNotifier: 加载失败 - $e');
      AppDialogs.showError('加载失败: $e');
    }
  }

  /// 检查并应用增量更新
  Future<void> checkAndUpdate() async {
    final manager = _manager;
    if (manager == null) {
      AppDialogs.showError('F-Droid 模块未启用');
      return;
    }
    try {
      final result = await manager.checkIncrementalUpdate();
      if (result == null) {
        AppDialogs.showInfo('检查更新失败');
        return;
      }

      final hasUpdate = result['hasUpdate'] ?? false;
      if (!hasUpdate) {
        AppDialogs.showInfo('已是最新版本');
        return;
      }

      await manager.applyIncrementalUpdate();
      await _loadStatistics();

      AppDialogs.showSuccess('更新完成');
    } catch (e) {
      AppDialogs.showError('更新失败: $e');
    }
  }

  /// 切换源
  Future<void> switchSource(FdroidSource source) async {
    final service = _service;
    if (service == null) {
      AppDialogs.showError('F-Droid 模块未启用');
      return;
    }
    try {
      await service.switchSource(source.id);

      await _loadStatistics();
      AppDialogs.showSuccess('已切换到 ${source.name}');
    } catch (e) {
      AppDialogs.showError('切换源失败: $e');
    }
  }

  /// 添加自定义源
  Future<void> addSource(BuildContext context) async {
    final nameController = TextEditingController();
    final urlController = TextEditingController();

    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (dialogContext) => Dialog(
        child: Padding(
          padding: AppSpacing.allLG,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('添加 F-Droid 源', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 16),
              TextField(
                controller: nameController,
                decoration: const InputDecoration(
                  labelText: '源名称',
                  hintText: '例如: 我的镜像源',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: urlController,
                decoration: const InputDecoration(
                  labelText: '仓库地址',
                  hintText: '例如: https://f-droid.org/repo',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: TextButton(
                      onPressed: () => Navigator.of(dialogContext).pop(),
                      child: const Text('取消'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () {
                        final name = nameController.text.trim();
                        final url = urlController.text.trim();
                        if (name.isEmpty || url.isEmpty) {
                          AppDialogs.showError('请填写完整信息');
                          return;
                        }
                        Navigator.of(dialogContext)
                            .pop({'name': name, 'url': url});
                      },
                      child: const Text('添加'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    nameController.dispose();
    urlController.dispose();

    if (result == null) return;

    final name = result['name'] as String;
    final url = result['url'] as String;

    try {
      // 验证 URL 格式
      final uri = Uri.parse(url);
      if (!uri.hasScheme || (!uri.scheme.startsWith('http'))) {
        AppDialogs.showError('请输入有效的 URL（以 http:// 或 https:// 开头）');
        return;
      }

      // 创建新源
      final newSource = FdroidSource(
        id: 'custom_${DateTime.now().millisecondsSinceEpoch}',
        name: name,
        repoUrl: url,
        enabled: true,
        priority: state.sources.length + 1,
      );

      final service = _service;
      if (service == null) {
        AppDialogs.showError('F-Droid 模块未启用');
        return;
      }

      // 通过 F-Droid 服务添加源
      await service.addSource(newSource);

      AppDialogs.showSuccess('已添加源：$name');
    } catch (e) {
      AppDialogs.showError('添加源失败: $e');
    }
  }

  /// 搜索应用
  Future<void> searchApps(String keyword) async {
    if (keyword.trim().isEmpty) {
      state = state.copyWith(searchResults: const []);
      return;
    }

    final service = _service;
    if (service == null) {
      state = state.copyWith(searchResults: const []);
      AppDialogs.showError('F-Droid 模块未启用');
      return;
    }

    try {
      state = state.copyWith(isSearching: true);

      final results = await service.searchApps(keyword, limit: 50);
      // 将 Map 转换为 FdroidApp 对象
      final fdroidApps = results.map((map) => FdroidApp(
        packageName: map['packageName'] ?? '',
        name: map['name'] ?? '',
        summary: map['summary'] ?? '',
        icon: map['icon'] ?? '',
        license: map['license'],
        authorName: map['authorName'],
        sourceCode: map['sourceCode'],
        webSite: map['webSite'],
        categories: map['categories']?.join(',') ?? '',
        added: map['added'],
        lastUpdated: map['lastUpdated'],
      )).toList();

      state = state.copyWith(searchResults: fdroidApps);
    } catch (e) {
      AppDialogs.showError('搜索失败: $e');
    } finally {
      state = state.copyWith(isSearching: false);
    }
  }

  /// 清空数据
  Future<void> clearData() async {
    final confirmed = await AppDialogs.showConfirmDialog(
      title: '确认清空',
      message: '确定要清空所有数据吗？此操作不可恢复。',
      confirmText: '确定',
      cancelText: '取消',
    );

    if (confirmed != true) return;

    final service = _service;
    if (service == null) {
      AppDialogs.showError('F-Droid 模块未启用');
      return;
    }

    try {
      await service.clearData();
      await _loadStatistics();
      AppDialogs.showSuccess('数据已清空');
    } catch (e) {
      AppDialogs.showError('清空失败: $e');
    }
  }

  /// 打开应用详情
  void openAppDetail(FdroidApp app) {
    // TODO: 导航到应用详情页
    AppDialogs.showInfo('应用详情功能开发中');
  }
}

/// F-Droid 仓库管理页 provider。
final fdroidRepoProvider =
    NotifierProvider<FdroidRepoNotifier, FdroidRepoState>(
  FdroidRepoNotifier.new,
);