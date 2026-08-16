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
import 'package:gstore/core/routers.dart';

/// 返回首页时重置键盘焦点
///
/// Flutter 路由 pop 存在焦点恢复机制：pop 回首页时会把焦点恢复到
/// 推入二级页前持有焦点的首页 TextField（搜索框/AI 输入栏），导致键盘自动弹出。
/// 此 observer 在 pop 回首页（previousRoute 为 home）后统一 unfocus，
/// 语义：返回首页不自动弹键盘（想继续输入点一下输入框即可）。
/// 不影响"搜索页 → 详情 → 返回搜索页"等键盘应保留的流程（previousRoute 非 home）。
class HomeFocusResetObserver extends NavigatorObserver {
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPop(route, previousRoute);
    if (previousRoute?.settings.name == AppRoute.home) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        FocusManager.instance.primaryFocus?.unfocus();
      });
    }
  }
}

/// M3 fadeThrough 近似全局页面过渡（交叉淡入 + 轻微上移）
///
/// Get（4.7.2）的 [CustomTransition] 是抽象类，需实现 buildTransition：
/// (context, curve, alignment, animation, secondaryAnimation, child)。
/// default: 分支（get_transition_mixin.dart:641）调用时 animation 已被
/// defaultTransitionCurve（easeOutQuad）包裹；忽略 secondaryAnimation
/// （fadeThrough 近似只做 primary 动画）。
class _FadeThroughPageTransition extends CustomTransition {
  @override
  Widget buildTransition(
    BuildContext context,
    Curve? curve,
    Alignment? alignment,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return FadeTransition(
      opacity: animation,
      child: SlideTransition(
        position: Tween<Offset>(begin: const Offset(0, 0.02), end: Offset.zero)
            .animate(animation),
        child: child,
      ),
    );
  }
}

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
  final appVersion = await AppVersionService.versionName() ?? 'unknown';
  appLog.info('应用启动', data: {
    'version': appVersion,
  });

  // 重定向 debugPrint 到 appLog（这样所有 debugPrint 都会进入日志查看器）
  // 默认映射为 debug 级别；重要流程/错误请使用 appLog.info / appLog.error
  // 过滤 flutter_gen_ai_chat_ui 库的内部调试噪音（消息流/滚动/状态机）
  debugPrint = (String? message, {int? wrapWidth}) {
    if (message == null) return;
    if (_isChatUiNoise(message)) return;
    appLog.debug(message);
  };

  Get.config(enableLog: true, defaultPopGesture: true);
  // 全局页面过渡：M3 fadeThrough 近似（交叉淡入 + 轻微上移，无位移过场）。
  // Get.customTransition 类型为 CustomTransition?（abstract class，非函数赋值），
  // default: 分支经 buildTransition 调用（get_transition_mixin.dart:641），
  // 传入的 animation 已被 Get 用 defaultTransitionCurve（easeOutQuad）包裹。
  Get.customTransition = _FadeThroughPageTransition();
  await registerService();

  runApp(DynamicColorBuilder(builder: (light, dark) {
    return Obx(() {
      final controller = Get.find<ThemeController>();
      return GetMaterialApp(
        // AppDialogs Snackbar 通道：ScaffoldMessenger 优先于 GetX overlay
        // （Get.snackbar 与新版 Flutter overlay 兼容问题导致真机提示静默不显示）
        scaffoldMessengerKey: AppDialogs.scaffoldMessengerKey,
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
        // 返回首页时重置键盘焦点（见 HomeFocusResetObserver）
        navigatorObservers: [HomeFocusResetObserver()],
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
