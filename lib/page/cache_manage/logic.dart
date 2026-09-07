import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:gstore/core/core.dart';

import 'cache_service.dart';
import 'state.dart';

/// 缓存管理页 Notifier（Riverpod）：驱动 [CacheManageService] 执行扫描/清理，
/// 维护页面响应式状态（loading/clearing/deletingIds + 数据快照）。
///
/// 页面通过 [cacheManageProvider] 读写；Agent 等无 UI 上下文调用方直接使用
/// [CacheManageService.instance]，不依赖本 Notifier。
class CacheManageNotifier extends Notifier<CacheManageState> {
  /// 测试注入：替代 [CacheManageService.instance] 的服务实例
  /// （测试用注入临时目录的 service，避免污染真实目录）。
  CacheManageService? debugService;

  CacheManageService get _service => debugService ?? CacheManageService.instance;

  @override
  CacheManageState build() {
    // 首帧加载（onInit 语义）；fire-and-forget，状态变更自动通知 UI
    Future.microtask(() async {
      await reload();
      await loadDownloads();
    });
    return const CacheManageState();
  }

  /// 统计全部缓存项大小并组装分组。
  Future<void> reload() async {
    state = state.copyWith(loading: true);
    try {
      final (groups, total) = await _service.scanCacheGroups();
      state = state.copyWith(groups: groups, totalSize: total);
    } catch (e) {
      appLog.error('CacheManage: 统计缓存大小失败 - $e');
      state = state.copyWith(groups: const [], totalSize: 0);
    } finally {
      state = state.copyWith(loading: false);
    }
  }

  /// 清理单项缓存。
  Future<bool> clearOne(String id) async {
    if (state.clearing.isNotEmpty) return false;
    state = state.copyWith(clearing: id);
    try {
      final ok = await _service.clearOne(id);
      if (!ok) return false;
      await reload();
      return true;
    } finally {
      state = state.copyWith(clearing: '');
    }
  }

  /// 一键清理全部缓存（需确认）。
  Future<bool> clearAll() async {
    if (state.clearing.isNotEmpty) return false;
    final dlCount = state.downloads.length;
    final ok = await AppDialogs.showConfirmDialog(
      title: '一键清理',
      message: '将清除全部缓存（网络图片 / README / 图标 / 通用缓存等），\n'
          '${dlCount > 0 ? '并删除已下载的 $dlCount 个安装包文件。\n' : ''}'
          '删除后不可恢复，请确认。',
      confirmText: '全部清理',
      isDangerous: true,
    );
    if (ok != true) return false;

    state = state.copyWith(clearing: '_all');
    try {
      // 1. 清理可再生缓存
      await _service.clearAllCaches();
      // 2. 删除全部已下载文件
      if (dlCount > 0) {
        final paths = state.downloads.map((e) => e.filePath).toList();
        await _service.deleteDownloads(paths);
      }
      await reload();
      await loadDownloads();
      return true;
    } finally {
      state = state.copyWith(clearing: '');
    }
  }

  // ---------- 已下载文件 ----------

  /// 刷新"已下载文件"列表。
  Future<void> loadDownloads() async {
    if (state.downloadsLoading) return;
    state = state.copyWith(downloadsLoading: true);
    try {
      final (items, total) = await _service.scanDownloads();
      state = state.copyWith(downloads: items, downloadTotalSize: total);
    } catch (e) {
      appLog.error('CacheManage: 加载已下载列表失败 - $e');
      state = state.copyWith(downloads: const [], downloadTotalSize: 0);
    } finally {
      state = state.copyWith(downloadsLoading: false);
    }
  }

  /// 批量删除选中的下载文件。返回删除成功条数。
  Future<int> deleteDownloads(List<String> filePaths) async {
    if (filePaths.isEmpty) return 0;
    // 锁定正在删除的文件，防止重复点击
    state = state.copyWith(
      deletingIds: {...state.deletingIds, ...filePaths},
    );
    try {
      final success = await _service.deleteDownloads(filePaths);
      await loadDownloads();
      return success;
    } finally {
      state = state.copyWith(
        deletingIds: state.deletingIds.difference(filePaths.toSet()),
      );
    }
  }

  /// 格式化字节数（供 UI 展示）。
  String formatSize(int bytes) => _service.formatSize(bytes);
}

/// 缓存管理页 provider。
final cacheManageProvider =
    NotifierProvider<CacheManageNotifier, CacheManageState>(
  CacheManageNotifier.new,
);
