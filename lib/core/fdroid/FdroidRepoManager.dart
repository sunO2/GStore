import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:get/get.dart';
import 'package:gstore/core/fdroid/FdroidRepoModels.dart';
import 'package:gstore/core/logger/LogManager.dart';
import 'package:gstore/core/rust/FdroidRustRepoManager.dart' as rust;
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// F-Droid 仓库管理器
/// 使用 Rust 实现提供更快的下载和解析速度
class FdroidRepoManager extends GetxController {
  static FdroidRepoManager? _instance;

  static FdroidRepoManager get instance {
    _instance ??= FdroidRepoManager._();
    return _instance!;
  }

  FdroidRepoManager._();

  /// 当前激活的源
  final Rx<FdroidSource?> currentSource = Rx<FdroidSource?>(null);

  /// 已配置的源列表
  final RxList<FdroidSource> sources = <FdroidSource>[].obs;

  /// 是否正在加载数据
  final RxBool isLoading = false.obs;

  /// 加载进度 (0-1)
  final RxDouble loadingProgress = 0.0.obs;

  /// 最后的错误信息
  final RxnString errorMessage = RxnString('');

  @override
  void onInit() {
    super.onInit();
    // 不自动初始化，需要手动调用 initialize()
  }

  /// 初始化管理器
  Future<void> initialize() async {
    try {
      debugPrint('FdroidRepoManager: 开始初始化...');

      // 初始化 Rust 后端
      final dbPath = path.join(
        (await _getApplicationDocumentsDirectory()).path,
        'fdroid_rust.db',
      );
      debugPrint('FdroidRepoManager: 初始化 Rust 后端，数据库路径: $dbPath');
      await rust.FdroidRustRepoManager.initialize(dbPath: dbPath);
      debugPrint('FdroidRepoManager: Rust 后端初始化成功');

      // 加载保存的源配置
      await _loadSources();
      debugPrint('FdroidRepoManager: 已加载 ${sources.length} 个源');

      // 设置默认源（如果没有保存的源，或者只有官方源，则添加清华镜像）
      if (sources.isEmpty || (sources.length == 1 && sources.first.id == 'official')) {
        debugPrint('FdroidRepoManager: 没有自定义源，添加清华镜像和官方源');
        sources.clear();
        sources.add(FdroidSource.tunaMirror); // 添加清华镜像（优先级更高）
        sources.add(FdroidSource.official); // 添加官方源作为备份
        await _saveSources();
      }

      // 设置当前源
      final enabledSource = sources.firstWhereOrNull((s) => s.enabled);
      debugPrint('FdroidRepoManager: 找到启用源: $enabledSource');

      // 尝试加载上次选中的源
      final prefs = await SharedPreferences.getInstance();
      final lastSourceId = prefs.getString('last_source_id');
      if (lastSourceId != null) {
        final lastSource = sources.firstWhereOrNull((s) => s.id == lastSourceId);
        if (lastSource != null) {
          currentSource.value = lastSource;
          debugPrint('FdroidRepoManager: 恢复上次选中的源: $lastSource');
        } else {
          currentSource.value = enabledSource;
        }
      } else {
        currentSource.value = enabledSource;
      }

      debugPrint('FdroidRepoManager: 初始化完成，当前源: ${currentSource.value}');
    } catch (e) {
      debugPrint('FdroidRepoManager: 初始化失败 - $e');
      errorMessage.value = '初始化失败: $e';
      rethrow;
    }
  }

  /// 加载保存的源配置
  Future<void> _loadSources() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final sourcesJson = prefs.getString('fdroid_sources');

      if (sourcesJson != null && sourcesJson.isNotEmpty) {
        final List<dynamic> sourcesList = jsonDecode(sourcesJson);
        final loadedSources = sourcesList
            .map((json) => FdroidSource.fromJson(json as Map<String, dynamic>))
            .toList();
        sources.clear();
        sources.addAll(loadedSources);
        debugPrint('FdroidRepoManager: 已加载 ${sources.length} 个保存的源');
      } else {
        sources.clear();
        debugPrint('FdroidRepoManager: 没有保存的源配置');
      }
    } catch (e) {
      debugPrint('FdroidRepoManager: 加载源配置失败 - $e');
      sources.clear();
    }
  }

  /// 保存源配置
  Future<void> _saveSources() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final sourcesJson = jsonEncode(sources.map((s) => s.toJson()).toList());
      await prefs.setString('fdroid_sources', sourcesJson);
      debugPrint('FdroidRepoManager: 已保存 ${sources.length} 个源配置');
    } catch (e) {
      debugPrint('FdroidRepoManager: 保存源配置失败 - $e');
    }
  }

  /// 切换源
  Future<void> switchSource(String sourceId) async {
    final source = sources.firstWhereOrNull((s) => s.id == sourceId);
    if (source == null) {
      throw Exception('未找到源: $sourceId');
    }

    if (!sources.contains(source)) {
      sources.add(source);
      await _saveSources();
    }

    currentSource.value = source;

    // 保存当前选中的源
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('last_source_id', sourceId);
    debugPrint('FdroidRepoManager: 已保存当前源: $sourceId');

    // 重新加载数据
    await loadRepository();
  }

  /// 获取源列表
  List<FdroidSource> getSources() {
    return sources.toList();
  }

  /// 获取当前源
  FdroidSource? getCurrentSource() {
    return currentSource.value;
  }

  /// 加载仓库数据
  Future<void> loadRepository({bool forceRefresh = false}) async {
    debugPrint('FdroidRepoManager: loadRepository 被调用');

    // 防止重复加载
    if (isLoading.value) {
      debugPrint('FdroidRepoManager: 已在加载中，跳过重复请求');
      return;
    }

    final source = currentSource.value;
    if (source == null) {
      debugPrint('FdroidRepoManager: 源为 null，返回错误');
      errorMessage.value = '请先选择一个源';
      return;
    }

    debugPrint('FdroidRepoManager: 开始加载源: ${source.name} (${source.repoUrl})');

    isLoading.value = true;
    errorMessage.value = '';
    loadingProgress.value = 0.0;

    try {
      debugPrint('FdroidRepoManager: 使用 Rust 后端下载...');
      loadingProgress.value = 0.5;

      await rust.FdroidRustRepoManager.downloadRepository(
        repoUrl: source.repoUrl,
      );

      loadingProgress.value = 1.0;
      debugPrint('FdroidRepoManager: Rust 后端下载完成');
      debugPrint('FdroidRepoManager: 仓库加载完成');
    } catch (e) {
      debugPrint('FdroidRepoManager: 加载仓库失败 - $e');
      errorMessage.value = '加载失败: $e';
      rethrow;
    } finally {
      isLoading.value = false;
    }
  }

  /// 搜索应用
  Future<List<Map<String, dynamic>>> searchApps(String keyword, {int limit = 50}) async {
    final source = currentSource.value;
    if (source == null) {
      throw Exception('请先选择一个源');
    }

    try {
      appLog.info('开始搜索 F-Droid 应用', data: {
        'keyword': keyword,
        'limit': limit,
        'source': source.name,
      });

      // 确保数据已加载
      final appCount = await rust.FdroidRustRepoManager.getAppCount();
      if (appCount == 0) {
        appLog.warning('数据库中没有应用，开始加载仓库');
        await loadRepository();
      }

      final results = await rust.FdroidRustRepoManager.searchApps(keyword, limit: limit);

      // 输出每个应用的详细信息到日志
      for (var i = 0; i < results.length; i++) {
        final app = results[i];
        final appMap = rust.FdroidRustRepoManager.appInfoToMap(app);

        appLog.info('应用 #${i + 1}/${results.length}', data: {
          'packageName': appMap['packageName'],
          'name': appMap['name'],
          'summary': appMap['summary'],
          'icon': appMap['icon'],
          'license': appMap['license'],
          'authorName': appMap['authorName'],
          'sourceCode': appMap['sourceCode'],
          'webSite': appMap['webSite'],
          'categories': appMap['categories'],
          'added': appMap['added'],
          'lastUpdated': appMap['lastUpdated'],
          'hasMetadata': appMap['metadata'] != null,
          'hasVersions': appMap['versions'] != null,
          'metadataLength': appMap['metadata']?.toString().length ?? 0,
          'versionsLength': appMap['versions']?.toString().length ?? 0,
        });
      }

      appLog.info('搜索完成', data: {
        'keyword': keyword,
        'resultCount': results.length,
      });

      return results.map((app) => rust.FdroidRustRepoManager.appInfoToMap(app)).toList();
    } catch (e) {
      appLog.error('搜索失败', data: {
        'keyword': keyword,
        'error': e.toString(),
      });
      debugPrint('FdroidRepoManager: 搜索失败 - $e');
      rethrow;
    }
  }

  /// 获取所有应用
  Future<List<Map<String, dynamic>>> getAllApps() async {
    final source = currentSource.value;
    if (source == null) {
      throw Exception('请先选择一个源');
    }

    try {
      appLog.info('开始获取所有 F-Droid 应用', data: {
        'source': source.name,
      });

      // 确保数据已加载
      final appCount = await rust.FdroidRustRepoManager.getAppCount();
      appLog.info('数据库应用数量', data: {
        'count': appCount,
      });

      if (appCount == 0) {
        appLog.warning('数据库中没有应用，开始加载仓库');
        await loadRepository();
      }

      // 搜索空字符串获取所有应用
      final results = await rust.FdroidRustRepoManager.searchApps('', limit: 100000);

      appLog.info('获取应用完成', data: {
        'totalApps': results.length,
      });

      // 输出前100个应用的详细信息（避免日志过多）
      final displayLimit = results.length > 100 ? 100 : results.length;
      for (var i = 0; i < displayLimit; i++) {
        final app = results[i];
        final appMap = rust.FdroidRustRepoManager.appInfoToMap(app);

        appLog.info('应用 #${i + 1}/$results.length', data: {
          'packageName': appMap['packageName'],
          'name': appMap['name'],
          'summary': appMap['summary'],
          'icon': appMap['icon'],
          'license': appMap['license'],
          'authorName': appMap['authorName'],
          'sourceCode': appMap['sourceCode'],
          'webSite': appMap['webSite'],
          'categories': appMap['categories'],
          'added': appMap['added'],
          'lastUpdated': appMap['lastUpdated'],
          'hasMetadata': appMap['metadata'] != null,
          'hasVersions': appMap['versions'] != null,
          'metadataLength': appMap['metadata']?.toString().length ?? 0,
          'versionsLength': appMap['versions']?.toString().length ?? 0,
        });
      }

      if (results.length > 100) {
        appLog.info('剩余应用已省略，仅显示前100个', data: {
          'total': results.length,
          'displayed': 100,
          'skipped': results.length - 100,
        });
      }

      return results.map((app) => rust.FdroidRustRepoManager.appInfoToMap(app)).toList();
    } catch (e) {
      appLog.error('获取所有应用失败', data: {
        'error': e.toString(),
      });
      debugPrint('FdroidRepoManager: 获取所有应用失败 - $e');
      rethrow;
    }
  }

  /// 获取应用数量
  Future<int> getAppCount() async {
    try {
      return await rust.FdroidRustRepoManager.getAppCount();
    } catch (e) {
      debugPrint('FdroidRepoManager: 获取应用数量失败 - $e');
      return 0;
    }
  }

  /// 获取数据库统计信息
  Future<Map<String, int>> getStatistics() async {
    try {
      final appCount = await rust.FdroidRustRepoManager.getAppCount();
      return {
        'apps': appCount,
      };
    } catch (e) {
      debugPrint('FdroidRepoManager: 获取统计信息失败 - $e');
      return {
        'apps': 0,
      };
    }
  }

  /// 添加自定义源
  Future<void> addSource(FdroidSource source) async {
    sources.add(source);
    await _saveSources();
  }

  /// 移除源
  Future<void> removeSource(String sourceId) async {
    sources.removeWhere((s) => s.id == sourceId);
    await _saveSources();

    // 如果删除的是当前源，切换到第一个可用源
    if (currentSource.value?.id == sourceId) {
      final nextSource = sources.firstWhereOrNull((s) => s.enabled);
      if (nextSource != null) {
        currentSource.value = nextSource;
      }
    }
  }

  /// 检查增量更新（Rust 暂不支持，返回 null）
  Future<Map<String, dynamic>?> checkIncrementalUpdate({bool force = false}) async {
    // Rust 实现暂时不支持增量更新
    debugPrint('FdroidRepoManager: 增量更新暂不支持');
    return null;
  }

  /// 应用增量更新（Rust 暂不支持）
  Future<void> applyIncrementalUpdate() async {
    // Rust 实现暂时不支持增量更新
    debugPrint('FdroidRepoManager: 增量更新暂不支持');
  }

  /// 清空当前数据
  Future<void> clearData() async {
    debugPrint('FdroidRepoManager: 开始清空数据...');

    try {
      // 调用 Rust 清空数据库
      final count = await rust.FdroidRustRepoManager.clearApps();
      debugPrint('FdroidRepoManager: 已清空 $count 个应用');
    } catch (e) {
      debugPrint('FdroidRepoManager: 清空数据失败 - $e');
      rethrow;
    }
  }

  /// 获取一个应用（用于调试）
  Future<Map<String, dynamic>?> getOneApp() async {
    try {
      final app = await rust.FdroidRustRepoManager.getOneApp();
      if (app != null) {
        return rust.FdroidRustRepoManager.appInfoToMap(app);
      }
      return null;
    } catch (e) {
      debugPrint('FdroidRepoManager: 获取应用失败 - $e');
      return null;
    }
  }

  /// 获取应用文档目录
  Future<Directory> _getApplicationDocumentsDirectory() async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      return directory;
    } catch (e) {
      debugPrint('FdroidRepoManager: 获取文档目录失败，使用默认路径: $e');
    }

    // 回退到简单实现
    final home = Platform.environment['HOME'];
    if (home != null) {
      return Directory(path.join(home, '.gstore'));
    }
    return Directory.current;
  }

  @override
  void onClose() {
    super.onClose();
  }
}
