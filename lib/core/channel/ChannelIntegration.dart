import 'dart:async' show unawaited;

import 'package:gstore/core/channel/channel.dart';
import 'package:gstore/core/channel/impl/channel_loader.dart';
import 'package:gstore/core/channel/script_ui_request_router.dart';
import 'package:gstore/core/script/script_ui_handler_registry.dart';
import 'package:gstore/core/logger/LogManager.dart';
import 'package:gstore/core/module/module_manager.dart';
import 'package:gstore/core/rust/ModuleManager.dart';
import 'package:gstore/http/github/dio_client.dart';
import 'package:gstore/http/github/github_client.dart';

/// 渠道系统初始化和配置
class ChannelIntegration {
  static ChannelManager? _manager;

  /// 幂等标志：首次初始化完成后置位，重复调用直接返回
  /// （防 channel 模块 re-enable 时重复 registerChannels / initializeAll）
  static bool _initialized = false;

  /// `script.ui_request` 路由是否已挂到模块事件广播流。
  static bool _scriptUiAttached = false;

  /// 把 Rust `script.ui_request` 接到 [ScriptUiRequestRouter]（幂等）。
  ///
  /// 只订阅既有广播流，不新建全局事件总线，也不影响
  /// [RustModuleManager.handleModuleEvent] 的既有处理器。
  static void _attachScriptUiRouter() {
    if (_scriptUiAttached) return;
    _scriptUiAttached = true;
    ScriptUiRequestRouter.instance
        .attachToModuleEvents(RustModuleManager.instance.moduleEvents);
    // Register all eight `ui.*` kinds behind the process-wide registry. The
    // detail page supplies/clears the active callbacks; a missing page is a
    // typed CORE_E_SCRIPT_UI_NO_ACTIVE_DETAIL, never `ui.<kind> 未注册`.
    ScriptUiHandlerRegistry.instance.registerOn(ScriptUiRequestRouter.instance);
  }

  static ChannelManager get manager {
    _manager ??= ChannelManager.instance;
    return _manager!;
  }

  /// 初始化渠道系统
  /// 在模块初始化（ChannelModule.onInit）中调用
  static Future<void> initialize() async {
    if (_initialized) return;

    final githubApi = ModuleManager.instance.require<GithubRestClient>();

    // 0. Rust `script.ui_request` → UI handler 回包（与既有模块事件共用一条流）
    _attachScriptUiRouter();

    // 1. 本地数据库渠道已下线：catalog 归 Rust core（`CatalogFacade` /
    //    `FrbCatalogBackend`），不再注册 Dart `LocalDbChannel`。

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
      githubChannel,
      vivoChannel,
      fdroidChannel,
    ]);

    // 5. 加载脚本渠道（用户渠道目录扫描；单个脚本失败跳过，不阻塞内置渠道）
    //    `CoreFlags.jsChannel == true`：`ChannelLoader` 把目录里的 zip 渠道包经
    //    `ScriptApi.init/import` 导入 Rust 脚本通道——这是生产环境的启动加载入口。
    //    Dart `JsChannel` 车道已在纯 Rust 清理中删除；flag off 时无脚本渠道车道。
    try {
      final loaded = await ChannelLoader().loadAndRegister();
      if (loaded.isEmpty && !manager.dartScriptChannelsEnabled) {
        appLog.info('ChannelIntegration: CoreFlags.jsChannel=true，'
            '脚本渠道包已交给 Rust ScriptApi 通道加载');
      }
    } catch (e) {
      appLog.error('ChannelIntegration: 脚本渠道加载失败（不影响内置渠道）: $e');
    }

    // 初始化所有启用的渠道
    await manager.initializeAll();

    // 默认渠道类型保持 `ChannelType.localDb`（ChannelManager 字段默认值），但不再
    // 注册 Dart 实例：catalog 读取统一走 `CatalogFacade`（Rust core）。

    _initialized = true;
  }

  /// 获取渠道管理器单例
  static ChannelManager get instance => manager;

  /// 重置状态（测试用）
  static void resetForTest() {
    _initialized = false;
    _manager = null;
    ScriptUiHandlerRegistry.instance.detach();
    if (_scriptUiAttached) {
      _scriptUiAttached = false;
      unawaited(ScriptUiRequestRouter.instance.detach());
    }
  }
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
