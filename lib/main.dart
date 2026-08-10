import 'dart:async';

import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:gstore/core/theme/theme_utils.dart';
import 'package:gstore/core/theme/theme_controller.dart';
import 'package:gstore/core/theme/theme_data_builder.dart';
import 'package:gstore/core/logger/LogManager.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'package:gstore/core/core.dart';
import 'package:gstore/core/module/app_modules.dart';
import 'package:gstore/core/module/infra_modules.dart';
import 'package:gstore/core/module/module.dart';
import 'package:gstore/core/module/module_manager.dart';

registerService() async {
  // 初始化日志管理器（必须在最开始，因为其他模块可能需要使用日志）
  Get.put(LogManager.instance);
  appLog.info('registerService: 开始');
  final sw = Stopwatch()..start();

  // 初始化模块中心：注入上下文（配置/Agent 工具/服务联动）并注册全部模块。
  // 模块通过 dependencies 声明依赖，ModuleManager 拓扑排序 + 分层并行初始化
  //（类似 Linux 包管理器：依赖就绪后才初始化下一层，同层无依赖模块并行）。
  await _initModuleManager(sw);

  // 初始化 Agent 智能助手服务（懒初始化，首次使用时创建）
  Get.lazyPut<AgentService>(() => AgentService());

  appLog.info('registerService: 全部初始化完成（总耗时 ${sw.elapsedMilliseconds}ms）');
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

/// 初始化模块中心
///
/// 1. 注入 ModuleContext：Agent 工具注册/注销、服务绑定/解绑、配置服务联动
/// 2. 注册全部基础设施 + 业务模块（登记，不初始化）
/// 3. initializeAll：按依赖拓扑排序分层并行初始化（onInit → onRegister）
Future<void> _initModuleManager(Stopwatch sw) async {
  final manager = ModuleManager.instance;

  manager.injectContext(ModuleContext(
    config: ConfigService.instance,
    bindService: (type, impl) => manager.bindByType(type, impl),
    unbindService: (type) => manager.unbindByType(type),
    manager: manager,
  ));

  // 内置模块清单（initializeModule 自动补注册依赖时查找）
  manager.registerKnownModules(() => [...InfraModules.all, ...CoreModules.all]);

  // 注册全部模块（登记，不初始化）
  manager.registerModule(LogModule());
  for (final module in InfraModules.all) {
    await manager.registerModule(module);
  }
  for (final module in CoreModules.all) {
    await manager.registerModule(module);
  }
  appLog.info('_initModuleManager: 已注册 ${manager.moduleCount} 个模块');

  // 按依赖拓扑排序分层并行初始化
  final initSw = Stopwatch()..start();
  await manager.initializeAll();
  initSw.stop();
  appLog.info('_initModuleManager: 全部模块初始化完成（${initSw.elapsedMilliseconds}ms）');
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
