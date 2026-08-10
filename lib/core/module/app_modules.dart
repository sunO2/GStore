/// 应用业务模块
///
/// 将 GStore 核心业务能力（渠道/下载/备份/WebDAV/F-Droid/主题/安装/聚合）
/// 封装为 AppModule，注册到 ModuleManager：
/// - 上线（onRegister）：绑定服务接口 + 注册配置（ConfigModule）+ 注册 Agent 工具
/// - 下线（onUnregister）：解绑服务接口 + 注销配置 + 注销 Agent 工具
///
/// 实现"模块上线注册、下线移除"的热插拔能力，
/// 调用方通过 ModuleManager.get<T>()（编译期绑定，0 损耗）
/// 或 DynamicProxy（延迟绑定）访问服务。
library;

import 'package:get/get.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/aggregate/AppAggregatorManager.dart';
import 'package:gstore/core/agent/agent_tool_module.dart';
import 'package:gstore/core/agent/tools/builtin_tools.dart';
import 'package:gstore/core/channel/ChannelManager.dart';
import 'package:gstore/core/config/config_registry.dart';
import 'package:gstore/core/fdroid/FdroidRepoManager.dart';
import 'package:gstore/core/module/module.dart';
import 'package:gstore/core/module/module_manager.dart';
import 'package:gstore/core/service/backup_service.dart';
import 'package:gstore/core/service/downloadService.dart';
import 'package:gstore/core/service/install_manager.dart';
import 'package:gstore/core/theme/theme_controller.dart';
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
      ];

  /// 注册全部内置业务模块到 ModuleManager
  static Future<void> registerAll(ModuleManager manager) async {
    for (final module in all) {
      await manager.registerModule(module);
    }
  }
}

/// 渠道模块
class ChannelModule extends AppModule {
  @override
  String get moduleName => 'channel';

  @override
  int get priority => 10;

  @override
  Future<void> onRegister(ModuleContext context) async {
    context.bindService?.call(IChannelService, ChannelManager.instance);
  }

  @override
  Future<void> onUnregister(ModuleContext context) async {
    context.unbindService?.call(IChannelService);
  }
}

/// 下载模块
class DownloadModule extends AppModule {
  @override
  String get moduleName => 'download';

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
    context.config?.unregisterModule('app_core');
  }
}

/// 备份模块
class BackupModule extends AppModule {
  @override
  String get moduleName => 'backup';

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

/// WebDAV 模块
class WebDavModule extends AppModule {
  @override
  String get moduleName => 'webdav';

  @override
  int get priority => 40;

  @override
  Future<void> onRegister(ModuleContext context) async {
    context.bindService?.call(IWebDavService, BackupService.instance);
  }

  @override
  Future<void> onUnregister(ModuleContext context) async {
    context.unbindService?.call(IWebDavService);
  }
}

/// F-Droid 模块
class FdroidModule extends AppModule {
  @override
  String get moduleName => 'fdroid';

  @override
  int get priority => 50;

  @override
  Future<void> onRegister(ModuleContext context) async {
    context.bindService?.call(IFdroidRepoService, FdroidRepoManager.instance);
  }

  @override
  Future<void> onUnregister(ModuleContext context) async {
    context.unbindService?.call(IFdroidRepoService);
  }
}

/// 主题模块
class ThemeModule extends AppModule {
  @override
  String get moduleName => 'theme';

  @override
  int get priority => 60;

  @override
  Future<void> onRegister(ModuleContext context) async {
    // ThemeController 由 main.dart 提前注册；此处容错获取
    try {
      context.bindService?.call(IThemeService, Get.find<ThemeController>());
    } catch (e) {
      appLog.error('ThemeModule: 绑定主题服务失败 - $e');
    }
  }

  @override
  Future<void> onUnregister(ModuleContext context) async {
    context.unbindService?.call(IThemeService);
  }
}

/// 安装模块
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

/// 聚合（我的应用）模块
class AggregateModule extends AppModule {
  @override
  String get moduleName => 'aggregate';

  @override
  int get priority => 80;

  @override
  Future<void> onRegister(ModuleContext context) async {
    context.bindService?.call(IAggregateService, AppAggregatorManager.instance);
  }

  @override
  Future<void> onUnregister(ModuleContext context) async {
    context.unbindService?.call(IAggregateService);
  }
}

/// Agent 工具模块
///
/// 上线时注册全部内置 Agent 工具（AgentService 拉取后模型可调用），
/// 下线时移除。通过 ModuleContext.registerAgentTools 联动。
class AgentToolsModule extends AppModule {
  @override
  String get moduleName => 'agent_tools';

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
