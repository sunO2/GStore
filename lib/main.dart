import 'dart:async';

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
import 'package:gstore/core/service/download_notification_service.dart';
import 'package:rhttp/rhttp.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'package:gstore/core/core.dart';
import 'package:gstore/core/config/config_initializer.dart';

registerService() async {
  // 初始化日志管理器（必须在最开始，因为其他模块可能需要使用日志）
  Get.put(LogManager.instance);
  appLog.info('registerService: 开始');

  // 初始化下载通知服务（通知栏进度 + 前台服务）
  await DownloadNotificationService.instance.init();
  appLog.info('registerService: 下载通知服务初始化完成');

  // 初始化 rhttp（基于 curl 的高性能 HTTP 客户端）
  // 必须在使用 RhttpAdapter 之前初始化
  try {
    await Rhttp.init();
    appLog.info('rhttp initialized successfully');
  } catch (e) {
    appLog.error('Failed to initialize rhttp, falling back to default adapter',
        data: {'error': e.toString()});
  }
  appLog.info('registerService: rhttp 初始化完成');

  // 注册 Dio 实例（供 FdroidRepoManager 使用）
  Get.lazyPut<Dio>(() => DioClient().get());

  Get.lazyPut<GithubRestClient>(() => GithubRestClient(DioClient().get()));
  await Get.putAsync<DbManager>(() async => await DbManager().init());
  appLog.info('registerService: DbManager 初始化完成');

  // OAuth API 需要使用单独的 Dio 实例（不包含 GitHub REST API 专用 headers）
  Get.lazyPut<GithubAuthApi>(() => GithubAuthApi(DioClient.createOAuthClient()));
  Get.lazyPut<DownloadService>(() => DownloadService(DioClient().get()));

  // 初始化 UserManager（使用单例模式）
  final userManager = UserManager.instance;
  Get.put(userManager);
  await userManager.initialize();
  appLog.info('registerService: UserManager 初始化完成');

  // 初始化数据库事件总线
  Get.put(DatabaseEventBus());

  // 初始化渠道系统
  await ChannelIntegration.initialize();
  appLog.info('registerService: 渠道初始化完成');

  // 初始化应用聚合管理器
  final aggregator = AppAggregatorManager.instance;
  await aggregator.initialize();
  Get.put(aggregator, tag: 'aggregatorManager');
  appLog.info('registerService: 聚合管理器初始化完成');

  // 初始化 F-Droid 仓库管理器
  final fdroidManager = FdroidRepoManager.instance;
  await fdroidManager.initialize();
  Get.put(fdroidManager);
  appLog.info('registerService: F-Droid 管理器初始化完成');

  // 初始化配置管理系统
  await ConfigInitializer.initialize();
  appLog.info('registerService: 配置管理系统初始化完成');

  // 初始化 Agent 智能助手服务（懒初始化，首次使用时创建）
  Get.lazyPut<AgentService>(() => AgentService());

  // 初始化红点服务
  Get.put(BadgeService());

  // 启动后异步检测红点（应用更新 / 数据库更新等），不阻塞 UI
  unawaited(BadgeService.instance.checkAll());
  appLog.info('registerService: 全部初始化完成');
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

  // 初始化前台任务通信端口（后台 isolate 保活）
  FlutterForegroundTask.initCommunicationPort();

  // 先初始化 LogManager（必须在最开始，用于拦截日志）
  Get.put(LogManager.instance);
  appLog.info('应用启动', data: {
    'version': '1.0.19',
  });

  // 重定向 debugPrint 到 appLog（这样所有 debugPrint 都会进入日志查看器）
  // 默认映射为 debug 级别；重要流程/错误请使用 appLog.info / appLog.error
  // 过滤 flutter_gen_ai_chat_ui 库的内部调试噪音（消息流/滚动/状态机）
  debugPrint = (String? message, {int? wrapWidth}) {
    if (message == null) return;
    if (_isChatUiNoise(message)) return;
    appLog.debug(message);
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

/// flutter_gen_ai_chat_ui 库内部调试日志的关键词
/// 这些日志不包含业务信息，仅库内部消息流/滚动/状态机调试，过滤掉避免刷屏
const List<String> _chatUiNoisePatterns = [
  'ChatMessagesController:',
  'MESSAGE TYPE:',
  'SCROLL DECISION:',
  'NOT SCROLLING:',
  'SCROLLING:',
  'Streaming message set to:',
  'USER MESSAGE:',
  'NEW RESPONSE:',
  'CHAIN MESSAGE:',
  'AiChatWidget:',
  'USER SCROLL:',
  'Manual scrolling',
];

/// 判断是否为 ai_chat_ui 库的内部噪音日志
bool _isChatUiNoise(String message) {
  for (final pattern in _chatUiNoisePatterns) {
    if (message.contains(pattern)) return true;
  }
  return false;
}
