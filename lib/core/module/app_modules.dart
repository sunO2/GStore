/// 应用业务模块
///
/// 将 GStore 核心业务能力（渠道/下载/备份/WebDAV/F-Droid/主题/安装/聚合/Agent 工具）
/// 封装为 AppModule，注册到 ModuleManager：
/// - 上线（onInit + onRegister）：依赖就绪后初始化自身并绑定服务/配置/工具
/// - 下线（onUnregister）：解绑服务接口 + 注销配置 + 注销 Agent 工具
///
/// 模块通过 dependencies 声明依赖（如 channel 依赖 db、backup 依赖 db+config+channel），
/// 由 ModuleManager 拓扑排序按依赖顺序初始化（类似 Linux 包管理器）。
library;

import 'package:get/get.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/aggregate/AppAggregatorManager.dart';
import 'package:gstore/core/agent/agent_tool_module.dart';
import 'package:gstore/core/agent/tools/builtin_tools.dart';
import 'package:gstore/core/channel/ChannelIntegration.dart';
import 'package:gstore/core/config/config_registry.dart';
import 'package:gstore/core/fdroid/FdroidRepoManager.dart';
import 'package:gstore/core/module/module.dart';
import 'package:gstore/core/module/module_manager.dart';
import 'package:gstore/core/service/backup_service.dart';
import 'package:gstore/core/service/badge_service.dart';
import 'package:gstore/core/service/downloadService.dart';
import 'package:gstore/core/service/install_manager.dart';
import 'package:gstore/core/theme/theme_controller.dart';
import 'package:gstore/core/webdav/webdav_service.dart';
import 'package:gstore/core/webdav/webdav_task_manager.dart';
import 'interfaces/service_interfaces.dart';

/// 核心业务模块注册器
///
/// 集中注册全部内置业务模块（启动时调用一次）。
class CoreModules {
  CoreModules._();

  /// 全部内置业务模块
  static List<AppModule> get all => [
        ChannelModule(),
        DownloadModule(),
        BackupModule(),
        WebDavModule(),
        FdroidModule(),
        ThemeModule(),
        InstallModule(),
        AggregateModule(),
        AgentToolsModule(),
        UpdateModule(),
        BadgeModule(),
      ];

  /// 注册全部内置业务模块到 ModuleManager
  static Future<void> registerAll(ModuleManager manager) async {
    for (final module in all) {
      await manager.registerModule(module);
    }
  }
}

/// 渠道模块（依赖 db）
class ChannelModule extends AppModule {
  @override
  String get moduleName => 'channel';

  @override
  List<String> get dependencies => const ['db'];

  @override
  int get priority => 10;

  @override
  Future<void> onInit(ModuleContext context) async {
    await ChannelIntegration.initialize();
  }

  @override
  Future<void> onRegister(ModuleContext context) async {}

  @override
  Future<void> onUnregister(ModuleContext context) async {}
}

/// 下载模块（依赖 channel + config）
class DownloadModule extends AppModule {
  @override
  String get moduleName => 'download';

  @override
  List<String> get dependencies => const ['channel', 'config'];

  @override
  int get priority => 20;

  @override
  Future<void> onRegister(ModuleContext context) async {
    final config = context.config;
    config?.registerModule(AppCoreConfigModule());
    context.bindService?.call(IDownloadService, Get.find<DownloadService>());
  }

  @override
  Future<void> onUnregister(ModuleContext context) async {
    context.unbindService?.call(IDownloadService);
    // 注意：不注销 app_core 配置——AppCoreConfigModule 持有 themeMode/webdavConfig/
    // proxyUrl/agentModels/fdroidSources 等全局配置 key（config_registry.dart:57-154），
    // 配置是全局的，不随 download 模块下线注销（否则运行期关 download 会清空整个配置注册表）。
  }
}

/// 备份模块（依赖 db + config + channel）
class BackupModule extends AppModule {
  @override
  String get moduleName => 'backup';

  @override
  List<String> get dependencies => const ['db', 'config', 'channel'];

  @override
  int get priority => 30;

  @override
  Future<void> onRegister(ModuleContext context) async {
    context.bindService?.call(IBackupService, BackupService.instance);
  }

  @override
  Future<void> onUnregister(ModuleContext context) async {
    context.unbindService?.call(IBackupService);
  }
}

/// WebDAV 模块（依赖 backup + config）
class WebDavModule extends AppModule {
  @override
  String get moduleName => 'webdav';

  @override
  List<String> get dependencies => const ['backup', 'config'];

  @override
  int get priority => 40;

  @override
  Future<void> onRegister(ModuleContext context) async {
    context.bindService?.call(IWebDavService, WebDavService.instance);
    context.bindService?.call(IWebDavTaskManager, WebDavTaskManager.instance);
  }

  @override
  Future<void> onUnregister(ModuleContext context) async {
    context.unbindService?.call(IWebDavService);
    context.unbindService?.call(IWebDavTaskManager);
  }
}

/// F-Droid 模块（依赖 config + db）
///
/// onInit 中完成 Rust 后端初始化（原 main.dart 迁入）。
class FdroidModule extends AppModule {
  @override
  String get moduleName => 'fdroid';

  @override
  List<String> get dependencies => const ['config', 'db'];

  @override
  int get priority => 50;

  @override
  Future<void> onInit(ModuleContext context) async {
    final fdroidManager = FdroidRepoManager.instance;
    try {
      await fdroidManager.initialize();
    } catch (e) {
      // Rust 库缺失/FFI/存储异常 → 降级：F-Droid 渠道懒初始化（不阻塞启动、不闪退）
      appLog.error('FdroidModule: F-Droid 初始化失败（降级，渠道懒初始化） - $e');
    }
    // 无论初始化成败都注册到 Get（失败时服务仍可解析，功能侧自行降级）
    if (!Get.isRegistered<FdroidRepoManager>()) {
      Get.put(fdroidManager);
    }
  }

  @override
  Future<void> onRegister(ModuleContext context) async {
    context.bindService?.call(IFdroidRepoService, FdroidRepoManager.instance);
  }

  @override
  Future<void> onUnregister(ModuleContext context) async {
    context.unbindService?.call(IFdroidRepoService);
  }
}

/// 主题模块（依赖 config）
///
/// onInit 中注册 ThemeController（原 main.dart 迁入）。
class ThemeModule extends AppModule {
  @override
  String get moduleName => 'theme';

  @override
  List<String> get dependencies => const ['config'];

  @override
  int get priority => 60;

  @override
  Future<void> onInit(ModuleContext context) async {
    if (!Get.isRegistered<ThemeController>()) {
      Get.put(ThemeController());
    }
  }

  @override
  Future<void> onRegister(ModuleContext context) async {
    context.bindService?.call(IThemeService, Get.find<ThemeController>());
  }

  @override
  Future<void> onUnregister(ModuleContext context) async {
    context.unbindService?.call(IThemeService);
  }
}

/// 安装模块（无依赖）
class InstallModule extends AppModule {
  @override
  String get moduleName => 'install';

  @override
  int get priority => 70;

  @override
  Future<void> onRegister(ModuleContext context) async {
    context.bindService?.call(IInstallService, InstallManager.instance);
  }

  @override
  Future<void> onUnregister(ModuleContext context) async {
    context.unbindService?.call(IInstallService);
  }
}

/// 聚合（我的应用）模块（依赖 db）
///
/// onInit 中完成聚合数据库初始化（原 main.dart 迁入）。
class AggregateModule extends AppModule {
  @override
  String get moduleName => 'aggregate';

  @override
  List<String> get dependencies => const ['db'];

  @override
  int get priority => 80;

  @override
  Future<void> onInit(ModuleContext context) async {
    final aggregator = AppAggregatorManager.instance;
    await aggregator.initialize();
    if (!Get.isRegistered<AppAggregatorManager>()) {
      Get.put(aggregator, tag: 'aggregatorManager');
    }
  }

  @override
  Future<void> onRegister(ModuleContext context) async {
    context.bindService?.call(IAggregateService, AppAggregatorManager.instance);
  }

  @override
  Future<void> onUnregister(ModuleContext context) async {
    context.unbindService?.call(IAggregateService);
  }
}

/// Agent 工具模块（依赖 config + channel）
///
/// 上线时注册全部内置 Agent 工具（AgentService 拉取后模型可调用），
/// 下线时移除。通过 ModuleContext.registerAgentTools 联动。
class AgentToolsModule extends AppModule {
  @override
  String get moduleName => 'agent_tools';

  @override
  List<String> get dependencies => const ['config', 'channel'];

  @override
  int get priority => 90;

  /// 内置工具模块列表
  List<AgentToolModule> get tools => BuiltinAgentTools.all;

  @override
  Future<void> onRegister(ModuleContext context) async {
    context.registerAgentTools?.call(tools);
  }

  @override
  Future<void> onUnregister(ModuleContext context) async {
    context.unregisterAgentTools?.call(tools.map((t) => t.toolName).toList());
  }
}

/// 更新管理模块（依赖 channel + aggregate）
///
/// 注册集中式 UpdateManager（统一检测入口 + 状态仓库）。
class UpdateModule extends AppModule {
  @override
  String get moduleName => 'update';

  @override
  List<String> get dependencies => const ['channel', 'aggregate'];

  @override
  int get priority => 95;

  @override
  Future<void> onInit(ModuleContext context) async {
    if (!Get.isRegistered<UpdateManagerService>()) {
      Get.put(UpdateManagerService());
    }
  }
}

/// 红点模块（依赖 channel + download + aggregate + update）
///
/// onInit 中注册 BadgeService 并异步触发红点检测（原 main.dart 迁入）。
class BadgeModule extends AppModule {
  @override
  String get moduleName => 'badge';

  @override
  List<String> get dependencies => const ['channel', 'download', 'aggregate', 'update'];

  @override
  int get priority => 100;

  @override
  Future<void> onInit(ModuleContext context) async {
    if (!Get.isRegistered<BadgeService>()) {
      Get.put(BadgeService());
    }
    // 启动后异步检测红点（应用更新走 UpdateManager 懒检测 / 数据库更新等），不阻塞 UI
    // catchError：检测异常不成为未处理异步异常（红点缺失可接受，不影响启动）
    unawaited(BadgeService.instance.checkAll().catchError((Object e, StackTrace st) {
      appLog.error('BadgeService: 启动检测异常 - $e');
    }));
  }
}
