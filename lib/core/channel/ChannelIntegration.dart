import 'package:gstore/core/channel/channel.dart';
import 'package:gstore/core/service/db_manager.dart';
import 'package:gstore/http/github/dio_client.dart';
import 'package:gstore/http/github/github_client.dart';
import 'package:dio/dio.dart';
import 'package:get/get.dart';

/// 渠道系统初始化和配置
class ChannelIntegration {
  static ChannelManager? _manager;

  /// 幂等标志：首次初始化完成后置位，重复调用直接返回
  /// （防 channel 模块 re-enable 时重复 registerChannels / Get.put / initializeAll）
  static bool _initialized = false;

  static ChannelManager get manager {
    _manager ??= ChannelManager.instance;
    return _manager!;
  }

  /// 初始化渠道系统
  /// 在 main.dart 的 registerService 中调用
  static Future<void> initialize() async {
    if (_initialized) return;

    final dbManager = Get.find<DbManager>();
    final githubApi = Get.find<GithubRestClient>();

    // 1. 注册本地数据库渠道
    var localDbChannel = LocalDbChannel(
      database: dbManager.dbRepositroies["gstore"]!.db,
      githubApi: githubApi, // 传入 GitHub API 用于查询 releases
      name: 'LocalDB',
      description: '本地数据库渠道（离线可用）',
      priority: 1,
    );

    // 2. 注册 GitHub API 渠道
    var githubChannel = GitHubChannel(
      githubApi: githubApi,
      name: 'GitHubAPI',
      description: 'GitHub API 渠道',
      priority: 2,
    );

    // 3. 注册 vivo 应用市场渠道
    var vivoChannel = VivoChannel(
      dio: DioClient().get(),
      name: 'vivo',
      description: 'vivo 应用市场',
      priority: 4,
    );

    // 4. 注册 F-Droid 应用市场渠道
    var fdroidChannel = FdroidChannel(
      dio: DioClient().get(),
      name: 'F-Droid',
      description: 'F-Droid 开源应用市场',
      priority: 5,
    );

    // 注册所有渠道
    manager.registerChannels([
      localDbChannel,
      githubChannel,
      vivoChannel,
      fdroidChannel,
    ]);

    // 初始化所有启用的渠道
    await manager.initializeAll();

    // 设置默认渠道
    manager.setDefaultChannel(ChannelType.localDb);

    Get.put(manager, tag: 'channelManager');

    _initialized = true;
  }

  /// 获取渠道管理器单例
  static ChannelManager get instance => manager;
}

// ==================== 使用示例 ====================

/// 示例 1: 基本使用 - 使用默认渠道
Future<void> example1_BasicUsage() async {
  final manager = ChannelManager.instance;

  // 获取所有应用（使用默认渠道）
  var result = await manager.getAllApps();
  if (result.success) {
    print('获取到 ${result.data!.length} 个应用');
    print('数据来源: ${result.from}');
  }
}

/// 示例 2: 指定渠道
Future<void> example2_SpecifyChannel() async {
  final manager = ChannelManager.instance;

  // 从本地数据库获取
  var localResult = await manager.getAllApps(from: ChannelType.localDb);

  // 从 GitHub API 获取
  var githubResult = await manager.getAllApps(from: ChannelType.github);
}

/// 示例 3: 自动降级（优先本地，失败则尝试 GitHub）
Future<void> example3_AutoFallback() async {
  final manager = ChannelManager.instance;

  // 按指定优先级尝试
  var result = await manager.getAllAppsWithFallback(
    preferredOrder: [
      ChannelType.localDb,
      ChannelType.github,
    ],
  );

  if (result.success) {
    print('从 ${result.from} 获取到数据');
  }
}

/// 示例 4: 搜索应用
Future<void> example4_Search() async {
  final manager = ChannelManager.instance;

  // 使用指定渠道搜索
  var result = await manager.searchApps(
    'browser',
    from: ChannelType.localDb,
  );

  if (result.success) {
    print('找到 ${result.data!.length} 个匹配应用');
  }
}

/// 示例 5: 按分类搜索
Future<void> example5_CategorySearch() async {
  final manager = ChannelManager.instance;

  var result = await manager.searchByCategory(
    'Tools',
    from: ChannelType.localDb,
  );

  if (result.success) {
    print('分类下有 ${result.data!.length} 个应用');
  }
}

/// 示例 6: 检查更新
Future<void> example6_CheckUpdate() async {
  final manager = ChannelManager.instance;

  // 检查指定渠道的更新
  var result = await manager.checkUpdate(from: ChannelType.localDb);

  if (result.success && result.data == true) {
    print('有新版本可用');
  }

  // 检查所有渠道的更新
  var allResults = await manager.checkAllUpdates();
  allResults.forEach((type, result) {
    print('$type: ${result.data ?? false}');
  });
}

/// 示例 7: 获取单个应用
Future<void> example7_GetAppInfo() async {
  final manager = ChannelManager.instance;

  var result = await manager.getAppInfo(
    'com.example.app',
    from: ChannelType.localDb,
  );

  if (result.success && result.data != null) {
    print('应用名称: ${result.data!.name}');
  }
}

/// 示例 8: UI 层使用（Logic 中）
///
/// 在 ApplistLogic 或 SearchLogic 中使用:
///
/// ```dart
/// class ApplistLogic extends GetxController {
///   final ApplistState state = ApplistState();
///   late ChannelManager _channelManager;
///
///   @override
///   void onReady() async {
///     super.onReady();
///     _channelManager = Get.find(tag: 'channelManager');
///     await _loadApps();
///   }
///
///   Future<void> _loadApps() async {
///     // 方式 1: 使用默认渠道
///     var result = await _channelManager.getAllApps();
///
///     // 方式 2: 指定渠道
///     // var result = await _channelManager.getAllApps(
///     //   from: ChannelType.localDb,
///     // );
///
///     // 方式 3: 自动降级
///     // var result = await _channelManager.getAllAppsWithFallback();
///
///     if (result.success) {
///       state.apps = result.data ?? [];
///       state.dataFrom = result.from; // 显示数据来源
///       update();
///     } else {
///       // 处理错误
///       showError(result.error ?? '加载失败');
///     }
///   }
///
///   void search(String keyword) async {
///     var result = await _channelManager.searchApps(
///       keyword,
///       from: ChannelType.localDb,
///     );
///
///     if (result.success) {
///       state.apps = result.data ?? [];
///       update();
///     }
///   }
/// }
/// ```

/// 示例 9: 添加自定义渠道
///
/// ```dart
/// class CustomChannel implements IChannel {
///   @override
///   ChannelInfo info = ChannelInfo(
///     type: ChannelType.custom,
///     name: 'CustomChannel',
///     description: '自定义数据源',
///   );
///
///   @override
///   bool isInitialized = false;
///
///   @override
///   Future<void> initialize() async {
///     // 初始化逻辑
///     isInitialized = true;
///   }
///
///   @override
///   Future<ChannelResult<List<AppInfo>>> getAllApps({
///     bool forceRefresh = false,
///   }) async {
///     // 实现数据获取逻辑
///     return ChannelResult.success(
///       data: [],
///       from: ChannelType.custom,
///     );
///   }
///
///   // 实现其他接口方法...
///   @override
///   Future<bool> checkAvailable() async => true;
///   @override
///   Future<void> dispose() async {}
///   @override
///   Future<ChannelResult<AppInfo?>> getAppInfo(String appId, {bool forceRefresh = false}) async {
///     return ChannelResult.success(data: null, from: ChannelType.custom);
///   }
///   @override
///   Future<ChannelResult<List<AppInfo>>> searchApps(String keyword, {bool forceRefresh = false}) async {
///     return ChannelResult.success(data: [], from: ChannelType.custom);
///   }
///   @override
///   Future<ChannelResult<List<AppInfo>>> searchByCategory(String categoryId, {bool forceRefresh = false}) async {
///     return ChannelResult.success(data: [], from: ChannelType.custom);
///   }
///   @override
///   Future<ChannelResult<List<AppCategory>>> getAllCategories({bool forceRefresh = false}) async {
///     return ChannelResult.success(data: [], from: ChannelType.custom);
///   }
///   @override
///   Future<ChannelResult<bool>> checkUpdate() async {
///     return ChannelResult.success(data: false, from: ChannelType.custom);
///   }
///   @override
///   Future<ChannelResult<bool>> doUpdate({Function(int p1, int p2)? onProgress}) async {
///     return ChannelResult.success(data: true, from: ChannelType.custom);
///   }
///   @override
///   Future<ChannelResult<AppInfoConfig?>> getConfig({bool forceRefresh = false}) async {
///     return ChannelResult.success(data: null, from: ChannelType.custom);
///   }
///   @override
///   Future<void> clearCache() async {}
///   @override
///   Future<int> getCacheSize() async => 0;
/// }
///
/// // 注册自定义渠道
/// void registerCustomChannel() {
///   var customChannel = CustomChannel();
///   ChannelManager.instance.registerChannel(customChannel);
/// }
/// ```
