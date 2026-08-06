import 'package:dio/dio.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:gstore/core/service/downloadService.dart';
import 'package:gstore/core/service/user_manager.dart';
import 'package:gstore/core/theme/theme_utils.dart';
import 'package:gstore/core/theme/theme_controller.dart';
import 'package:gstore/core/theme/theme_data_builder.dart';
import 'package:gstore/http/github/dio_client.dart';
import 'package:gstore/http/github/github_auth_api.dart';
import 'package:gstore/http/github/github_client.dart';
import 'package:gstore/core/channel/ChannelIntegration.dart';
import 'package:gstore/core/aggregate/AppAggregatorManager.dart';
import 'package:gstore/core/fdroid/FdroidRepoManager.dart';
import 'package:gstore/core/logger/LogManager.dart';
import 'package:gstore/core/event/database_event.dart';
import 'package:rhttp/rhttp.dart';

import 'package:gstore/core/core.dart';
import 'package:gstore/core/config/config_initializer.dart';

registerService() async {
  // 初始化日志管理器（必须在最开始，因为其他模块可能需要使用日志）
  Get.put(LogManager.instance);

  // 初始化 rhttp（基于 curl 的高性能 HTTP 客户端）
  // 必须在使用 RhttpAdapter 之前初始化
  try {
    await Rhttp.init();
    appLog.info('rhttp initialized successfully');
  } catch (e) {
    appLog.error('Failed to initialize rhttp, falling back to default adapter',
        data: {'error': e.toString()});
  }

  // 注册 Dio 实例（供 FdroidRepoManager 使用）
  Get.lazyPut<Dio>(() => DioClient().get());

  Get.lazyPut<GithubRestClient>(() => GithubRestClient(DioClient().get()));
  await Get.putAsync<DbManager>(() async => await DbManager().init());

  // OAuth API 需要使用单独的 Dio 实例（不包含 GitHub REST API 专用 headers）
  Get.lazyPut<GithubAuthApi>(() => GithubAuthApi(DioClient.createOAuthClient()));
  Get.lazyPut<DownloadService>(() => DownloadService(DioClient().get()));

  // 初始化 UserManager（使用单例模式）
  final userManager = UserManager.instance;
  Get.put(userManager);
  await userManager.initialize();

  // 初始化数据库事件总线
  Get.put(DatabaseEventBus());

  // 初始化渠道系统
  await ChannelIntegration.initialize();

  // 初始化应用聚合管理器
  final aggregator = AppAggregatorManager.instance;
  await aggregator.initialize();
  Get.put(aggregator, tag: 'aggregatorManager');

  // 初始化 F-Droid 仓库管理器
  final fdroidManager = FdroidRepoManager.instance;
  await fdroidManager.initialize();
  Get.put(fdroidManager);

  // 初始化配置管理系统
  await ConfigInitializer.initialize();

  // 初始化 Agent 智能助手服务（懒初始化，首次使用时创建）
  Get.lazyPut<AgentService>(() => AgentService());
}

colorSchemeSeed(ColorScheme? color, Brightness brightness) {
  if (null == color) {
    if (brightness == Brightness.light) {
      return ColorScheme.dark(brightness: brightness);
    } else {
      return ColorScheme.light(brightness: brightness);
    }
  }
  return color;
}

main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 先初始化 LogManager（必须在最开始，用于拦截日志）
  Get.put(LogManager.instance);
  appLog.info('应用启动', data: {
    'version': '1.0.19',
  });

  // 重定向 debugPrint 到 appLog（这样所有 debugPrint 都会进入日志查看器）
  debugPrint = (String? message, {int? wrapWidth}) {
    if (message != null) {
      appLog.info(message);
    }
  };

  Get.config(
      enableLog: true,
      defaultPopGesture: true,
      defaultTransition: Transition.cupertino);
  await registerService();

  // 初始化主题控制器
  Get.put(ThemeController());

  runApp(DynamicColorBuilder(builder: (light, dark) {
    return Obx(() {
      final controller = Get.find<ThemeController>();
      return GetMaterialApp(
        builder: (context, child) {
          configStatusBar();
          return Material(
            child: SafeArea(
              top: false,
              bottom: false,
              child: child!,
            ),
          );
        },
        initialRoute: AppRoute.home,
        getPages: AppRoute.pages,
        themeMode: controller.themeModeValue,
        theme: ThemeDataBuilder.buildLightTheme(
          light,
          config: controller.themeConfig,
        ),
        darkTheme: ThemeDataBuilder.buildDarkTheme(
          dark,
          config: controller.themeConfig,
        ),
      );
    });
  }));
}
