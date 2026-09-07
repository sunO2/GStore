/// 基础设施模块
///
/// 把应用启动所需的基础设施初始化（日志/配置/rhttp/数据库/通知/用户）
/// 封装为 AppModule，通过 ModuleManager 按依赖拓扑排序初始化。
///
/// 依赖关系（类似 Linux 包管理器）：
/// - log / config / db / notification 无依赖（第一层并行）
/// - rhttp 依赖 log
/// - user 依赖 db + rhttp
library;

import 'package:dio/dio.dart';
import 'package:rhttp/rhttp.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/config/config_initializer.dart';
import 'package:gstore/core/config/config_service.dart';
import 'package:gstore/core/download/core/dio_download_engine.dart';
import 'package:gstore/core/download/manager/download_manager.dart';
import 'package:gstore/core/download/manager/download_repository.dart';
import 'package:gstore/core/event/database_event.dart';
import 'package:gstore/core/module/module.dart';
import 'package:gstore/core/service/db_manager.dart';
import 'package:gstore/core/service/download_notification_service.dart';
import 'package:gstore/core/service/metadata_submit_service.dart';
import 'package:gstore/core/service/user_manager.dart';
import 'package:gstore/http/github/dio_client.dart';
import 'package:gstore/http/github/github_auth_api.dart';
import 'package:gstore/http/github/github_client.dart';

/// 基础设施模块注册器
class InfraModules {
  InfraModules._();

  /// 全部基础设施模块
  static List<AppModule> get all => [
        LogModule(),
        ConfigModule(),
        NotificationModule(),
        RhttpModule(),
        DbModule(),
        UserModule(),
      ];
}

/// 日志模块（无依赖，最先初始化）
class LogModule extends AppModule {
  @override
  String get moduleName => 'log';

  @override
  int get priority => 1;

  @override
  Future<void> onInit(ModuleContext context) async {
    // 单例注册进模块注册表（main() 可能已触发初始化；bind 幂等覆盖）
    ModuleManager.instance.bind<LogManager>(LogManager.instance);
  }
}

/// 配置模块（无依赖）
///
/// 初始化 ConfigService/ConfigStore/注册表，并启动代理配置桥接。
class ConfigModule extends AppModule {
  @override
  String get moduleName => 'config';

  @override
  int get priority => 2;

  @override
  Future<void> onInit(ModuleContext context) async {
    await ConfigInitializer.initialize();
    // 代理配置 B 轨：从 ConfigService 加载并订阅 proxy_url 变化（getProxy 即时生效）
    await loadProxyFromConfig();
  }

  @override
  Future<void> onRegister(ModuleContext context) async {
    context.bindService?.call(ConfigService, ConfigService.instance);
  }
}

/// 通知服务模块（无依赖）
class NotificationModule extends AppModule {
  @override
  String get moduleName => 'notification';

  @override
  int get priority => 3;

  @override
  Future<void> onInit(ModuleContext context) async {
    await DownloadNotificationService.instance.init();
  }
}

/// rhttp 模块（依赖 log）
class RhttpModule extends AppModule {
  @override
  String get moduleName => 'rhttp';

  @override
  List<String> get dependencies => const ['log'];

  @override
  int get priority => 4;

  @override
  Future<void> onInit(ModuleContext context) async {
    try {
      await Rhttp.init();
      appLog.info('rhttp initialized successfully');
    } catch (e) {
      appLog.error('Failed to initialize rhttp, falling back to default adapter',
          data: {'error': e.toString()});
    }
  }
}

/// 数据库模块（无依赖）
///
/// 初始化 DbManager，注册 Dio/GitHub API/DownloadService 等懒实例。
class DbModule extends AppModule {
  @override
  String get moduleName => 'db';

  @override
  int get priority => 5;

  @override
  Future<void> onInit(ModuleContext context) async {
    final manager = ModuleManager.instance;
    // 注册 Dio 实例（供 FdroidRepoManager 使用）
    manager.lazyPut<Dio>(() => DioClient().get());
    manager.lazyPut<GithubRestClient>(() => GithubRestClient(DioClient().get()));
    // OAuth API 需要使用单独的 Dio 实例（不包含 GitHub REST API 专用 headers）
    manager.lazyPut<GithubAuthApi>(() => GithubAuthApi(DioClient.createOAuthClient()));
    manager.lazyPut<DownloadManager>(() => DownloadManager(
          engine: DioDownloadEngine(dio: DioClient().get()),
          repository: DownloadRepository(),
          onApkReady: (filePath) {
            final m = manager.get<InstallManager>();
            if (m != null) m.installApk(filePath);
          },
        ));

    await DbManager().init();
    manager.bind<DbManager>(DbManager.instance);
    manager.bind<DatabaseEventBus>(DatabaseEventBus.instance);
  }

  @override
  Future<void> onRegister(ModuleContext context) async {
    context.bindService?.call(DbManager, DbManager.instance);
  }
}

/// 用户模块（依赖 db + rhttp）
class UserModule extends AppModule {
  @override
  String get moduleName => 'user';

  @override
  List<String> get dependencies => const ['db', 'rhttp'];

  @override
  int get priority => 6;

  @override
  Future<void> onInit(ModuleContext context) async {
    final userManager = UserManager.instance;
    ModuleManager.instance.bind<UserManager>(userManager);
    await userManager.initialize();
    // 元数据提交服务（依赖用户登录态，首次使用时创建）
    ModuleManager.instance.lazyPut<MetadataSubmitService>(
        () => MetadataSubmitService.instance);
  }
}
