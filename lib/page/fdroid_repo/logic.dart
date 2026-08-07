/// F-Droid 仓库管理页面业务逻辑
library;

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:gstore/core/design/design_tokens.dart';
import 'package:gstore/core/fdroid/FdroidRepoManager.dart';
import 'package:gstore/core/fdroid/FdroidRepoModels.dart';
import 'package:gstore/core/logger/LogManager.dart';
import 'package:gstore/page/fdroid_repo/state.dart';

/// F-Droid 仓库管理业务逻辑
class FdroidRepoLogic extends GetxController {
  final FdroidRepoState state = FdroidRepoState();
  late FdroidRepoManager _manager;

  final TextEditingController searchController = TextEditingController();

  @override
  void onInit() {
    super.onInit();
    _manager = Get.find<FdroidRepoManager>();
    _initData();

    // 监听加载进度
    ever(_manager.loadingProgress, (progress) {
      state.loadingProgress.value = progress * 100;
    });

    // 监听加载状态
    ever(_manager.isLoading, (loading) {
      state.isLoading.value = loading;
    });

    // 监听错误信息
    ever(_manager.errorMessage, (error) {
      if (error?.isNotEmpty == true) {
        state.errorMessage.value = error;
      }
    });

    // 监听源列表变化
    ever(_manager.sources, (sources) {
      state.sources.value = sources;
    });

    // 监听当前源变化
    ever(_manager.currentSource, (source) {
      state.currentSource.value = source;
    });
  }

  @override
  void onClose() {
    searchController.dispose();
    super.onClose();
  }

  /// 初始化数据
  Future<void> _initData() async {
    try {
      // 加载源列表
      state.sources.value = await _manager.getSources();
      state.currentSource.value = await _manager.getCurrentSource();

      // 加载统计信息
      await _loadStatistics();

      // 检查更新
      await _checkUpdate();
    } catch (e) {
      state.errorMessage.value = '初始化失败: $e';
    }
  }

  /// 加载统计信息
  Future<void> _loadStatistics() async {
    try {
      state.statistics.value = await _manager.getStatistics();
    } catch (e) {
      appLog.error('加载统计信息失败: $e');
    }
  }

  /// 检查更新
  Future<void> _checkUpdate() async {
    try {
      final result = await _manager.checkIncrementalUpdate();
      if (result != null) {
        state.hasUpdate.value = result['hasUpdate'] ?? false;
        state.currentVersion.value = result['currentVersion'] ?? 0;
        state.latestVersion.value = result['latestVersion'] ?? 0;
      }
    } catch (e) {
      appLog.error('检查更新失败: $e');
    }
  }

  /// 加载仓库数据
  Future<void> loadRepository() async {
    debugPrint('FdroidRepoLogic: loadRepository 被调用');
    debugPrint('FdroidRepoLogic: state.currentSource.value = ${state.currentSource.value}');
    debugPrint('FdroidRepoLogic: _manager.currentSource.value = ${_manager.currentSource.value}');

    if (state.currentSource.value == null) {
      debugPrint('FdroidRepoLogic: currentSource 为 null，尝试从 manager 同步');
      state.currentSource.value = _manager.currentSource.value;
    }

    if (state.currentSource.value == null) {
      AppDialogs.showError('请先选择一个源');
      return;
    }

    try {
      appLog.info('FdroidRepoLogic: 开始加载仓库: ${state.currentSource.value?.repoUrl}');
      await _manager.loadRepository();

      await _loadStatistics();
      AppDialogs.showSuccess('仓库数据加载完成');
    } catch (e) {
      appLog.error('FdroidRepoLogic: 加载失败 - $e');
      AppDialogs.showError('加载失败: $e');
    }
  }

  /// 检查并应用增量更新
  Future<void> checkAndUpdate() async {
    try {
      final result = await _manager.checkIncrementalUpdate();
      if (result == null) {
        AppDialogs.showInfo('检查更新失败');
        return;
      }

      final hasUpdate = result['hasUpdate'] ?? false;
      if (!hasUpdate) {
        AppDialogs.showInfo('已是最新版本');
        return;
      }

      await _manager.applyIncrementalUpdate();
      await _loadStatistics();

      AppDialogs.showSuccess('更新完成');
    } catch (e) {
      AppDialogs.showError('更新失败: $e');
    }
  }

  /// 切换源
  Future<void> switchSource(FdroidSource source) async {
    try {
      await _manager.switchSource(source.id);

      await _loadStatistics();
      AppDialogs.showSuccess('已切换到 ${source.name}');
    } catch (e) {
      AppDialogs.showError('切换源失败: $e');
    }
  }

  /// 添加自定义源
  Future<void> addSource() async {
    final nameController = TextEditingController();
    final urlController = TextEditingController();

    final result = await Get.dialog(
      Dialog(
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
                      onPressed: () => Get.back(),
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
                        Get.back(result: {'name': name, 'url': url});
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

      // 通过 FdroidRepoManager 添加源
      await _manager.addSource(newSource);

      AppDialogs.showSuccess('已添加源：$name');
    } catch (e) {
      AppDialogs.showError('添加源失败: $e');
    }
  }

  /// 搜索应用
  Future<void> searchApps(String keyword) async {
    if (keyword.trim().isEmpty) {
      state.searchResults.clear();
      return;
    }

    try {
      state.isSearching.value = true;

      final results = await _manager.searchApps(keyword, limit: 50);
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

      state.searchResults.value = fdroidApps;
    } catch (e) {
      AppDialogs.showError('搜索失败: $e');
    } finally {
      state.isSearching.value = false;
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

    try {
      await _manager.clearData();
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
