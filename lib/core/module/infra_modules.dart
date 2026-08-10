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
import 'package:get/get.dart';
import 'package:rhttp/rhttp.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/config/config_initializer.dart';
import 'package:gstore/core/config/config_service.dart';
import 'package:gstore/core/event/database_event.dart';
import 'package:gstore/core/module/module.dart';
import 'package:gstore/core/service/db_manager.dart';
import 'package:gstore/core/service/download_notification_service.dart';
import 'package:gstore/core/service/downloadService.dart';
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
    // main() 可能已 put（须最先拦截日志）；此处幂等
    if (!Get.isRegistered<LogManager>()) {
      Get.put(LogManager.instance);
    }
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
    // 启动代理配置桥接（ConfigService proxy_url 变化 → getProxy 立即生效）
    startProxyConfigBridge();
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
    // 注册 Dio 实例（供 FdroidRepoManager 使用）
    Get.lazyPut<Dio>(() => DioClient().get());
    Get.lazyPut<GithubRestClient>(() => GithubRestClient(DioClient().get()));
    // OAuth API 需要使用单独的 Dio 实例（不包含 GitHub REST API 专用 headers）
    Get.lazyPut<GithubAuthApi>(() => GithubAuthApi(DioClient.createOAuthClient()));
    Get.lazyPut<DownloadService>(() => DownloadService(DioClient().get()));

    await Get.putAsync<DbManager>(() async => await DbManager().init());
    Get.put(DatabaseEventBus());
  }

  @override
  Future<void> onRegister(ModuleContext context) async {
    context.bindService?.call(DbManager, Get.find<DbManager>());
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
    if (!Get.isRegistered<UserManager>()) {
      Get.put(userManager);
    }
    await userManager.initialize();
  }
}
