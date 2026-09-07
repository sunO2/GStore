import 'dart:async';
import 'dart:io';

import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gstore/core/theme/theme_utils.dart';
import 'package:gstore/core/theme/theme_provider.dart';
import 'package:gstore/core/theme/theme_data_builder.dart';
import 'package:gstore/core/logger/LogManager.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'package:gstore/core/core.dart';
import 'package:gstore/core/config/config_initializer.dart';
import 'package:gstore/core/module/app_modules.dart';
import 'package:gstore/core/module/infra_modules.dart';
import 'package:gstore/core/module/module.dart';
import 'package:gstore/core/module/module_manager.dart';
import 'package:gstore/core/module/module_toggle_config.dart';
import 'package:gstore/core/navigation/nav_key.dart';
import 'package:gstore/core/router/app_router.dart';
import 'package:gstore/core/routers.dart';

/// 首页焦点重置与全局转场已迁移至 lib/core/router/app_router.dart
/// （HomeFocusResetObserver）与主题 pageTransitionsTheme（转场复刻）。

registerService() async {
  // LogManager 单例惰性初始化（appLog 首次访问即创建；LogModule 负责注册到注册表）
  appLog.info('registerService: 开始');
  final sw = Stopwatch()..start();

  // 初始化模块中心：注入上下文（配置/Agent 工具/服务联动）并注册全部模块。
  // 模块通过 dependencies 声明依赖，ModuleManager 拓扑排序 + 分层并行初始化
  //（类似 Linux 包管理器：依赖就绪后才初始化下一层，同层无依赖模块并行）。
  await _initModuleManager(sw);

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

  // 模块开关预置：按持久化配置禁用（仅 9 个可开关业务模块；update/badge/infra 恒启用）。
  // 必须位于 registerModule 循环之后、initializeAll 之前——disabled 模块启动即跳过
  //（_initModule 短路，isInitialized 保持 false，业务模块启动跳过真实生效）。
  await ModuleToggleConfig.preApplyToggles(manager);

  // 按依赖拓扑排序分层并行初始化
  // 任一模块 onInit/onRegister 抛异常 → 记录日志后降级继续启动（不闪退），
  // 已初始化模块的服务保持可用，失败模块对应功能降级（日志查看器可见）。
  final initSw = Stopwatch()..start();
  try {
    await manager.initializeAll();
    initSw.stop();
    appLog.info('_initModuleManager: 全部模块初始化完成（${initSw.elapsedMilliseconds}ms）');
  } catch (e, st) {
    initSw.stop();
    appLog.error('_initModuleManager: 模块初始化异常（降级继续启动）', data: {
      'elapsedMs': initSw.elapsedMilliseconds,
      'error': e.toString(),
      'stack': st.toString(),
    });
  }
}

main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 初始化前台任务通信端口（后台 isolate 保活）
  FlutterForegroundTask.initCommunicationPort();

  // LogManager 惰性单例（appLog 首次访问即创建，用于拦截日志）
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

  // 配置系统前置初始化（静态 _initialized 幂等；ConfigModule.onInit 保留原调用，
  // 第二次调用为 no-op）。必须在 registerService 之前：启动装配
  //（_initModuleManager 预置禁用）需要按持久化开关读配置。
  await ConfigInitializer.initialize();
  await registerService();

  // 系统"管理空间"入口（ManageSpaceActivity）：Android 系统设置 →
  // 应用 → GStore → 存储 → 管理空间。中转 Activity 会复用 MainActivity
  // 并置位一次性请求标记，此处消费（冷启动）并交由 _ManageSpaceRouter
  // 在首帧后跳转缓存管理页（返回键回首页）；后台恢复场景由 Router 监听处理。
  _ManageSpaceRouterState.coldHit = await _consumeManageSpaceEntry();

  // 把 GoRouter 的 Navigator 注册为 GetX 全局 navigator key：
  // GetX overlay（Get.dialog/bottomSheet/snackbar）在 MaterialApp.router 下继续可用
  // （状态管理 Get.put/Obx 与之无关，天然可用）。
  Get.addKey(appNavigatorKey);

  // ProviderScope：Riverpod 根容器（与 GetX DI 共存；已迁移页面使用 ConsumerWidget/Notifier）
  runApp(ProviderScope(
    child: DynamicColorBuilder(builder: (light, dark) {
      return Consumer(builder: (context, ref, _) {
        // 主题状态由 Riverpod 权威管理（themeProvider 常驻，不随 theme 模块
        // 上下线而失效——模块开关只影响 IThemeService 服务绑定/agent 工具）
        final theme = ref.watch(themeProvider);
        return _ManageSpaceRouter(
          child: MaterialApp.router(
            // AppDialogs Snackbar 通道：ScaffoldMessenger 优先于 GetX overlay
            scaffoldMessengerKey: AppDialogs.scaffoldMessengerKey,
            routerConfig: appRouter,
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
            themeMode: theme.themeModeValue,
            theme: ThemeDataBuilder.buildLightTheme(
              light,
              config: theme.config,
            ),
            darkTheme: ThemeDataBuilder.buildDarkTheme(
              dark,
              config: theme.config,
            ),
          ),
        );
      });
    }),
  ));
}

/// 消费"管理空间"入口请求。
///
/// MainActivity 冷启动（onCreate）或热启动（onNewIntent）收到
/// ManageSpaceActivity 转发的请求后置位一次性标记，此处经 MethodChannel
/// `consumeManageSpace` 查询并消费。非 Android / 普通启动 → false，零开销。
Future<bool> _consumeManageSpaceEntry() async {
  if (!Platform.isAndroid) return false;
  try {
    const channel = MethodChannel('gstore/manage_space');
    final hit = await channel.invokeMethod<bool>('consumeManageSpace');
    if (hit == true) {
      appLog.info('启动入口：系统"管理空间"请求已消费，将跳转缓存管理页');
    }
    return hit == true;
  } catch (e) {
    return false;
  }
}

/// 管理空间入口路由封装。
///
/// 冷启动时 main() 已在 runApp 前消费过一次请求（[coldManageSpace] 为 true），
/// 此处等首帧渲染完成后 push 缓存管理页（在首页之上，返回键回首页）；
/// 应用已在后台运行时 main() 不会重跑，原生 onNewIntent 置位发生在引擎存活期，
/// 故监听 AppLifecycleState.resumed 再次消费——回到前台即跳转。
class _ManageSpaceRouter extends StatefulWidget {
  const _ManageSpaceRouter({required this.child});

  final Widget child;

  @override
  State<_ManageSpaceRouter> createState() => _ManageSpaceRouterState();
}

class _ManageSpaceRouterState extends State<_ManageSpaceRouter>
    with WidgetsBindingObserver {
  /// 冷启动消费结果（main() 在 runApp 前写入）。
  static bool coldHit = false;

  /// 首帧跳转是否已执行（防重复 push）。
  bool _handledCold = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 冷启动：首帧后跳转（此时 GetMaterialApp 路由已就绪）
    if (coldHit) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _handledCold) return;
        _handledCold = true;
        _openCacheManage();
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 热启动恢复：应用已在后台被 ManageSpaceActivity 带回前台，onNewIntent
    // 已在原生置位 → 回到 resumed 时消费并跳转
    if (state == AppLifecycleState.resumed) {
      _consumeOnResume();
    }
  }

  Future<void> _consumeOnResume() async {
    if (!Platform.isAndroid) return;
    try {
      const channel = MethodChannel('gstore/manage_space');
      final hit = await channel.invokeMethod<bool>('consumeManageSpace');
      if (hit == true && mounted) {
        appLog.info('后台恢复：消费系统"管理空间"请求，跳转缓存管理页');
        _openCacheManage();
      }
    } catch (_) {
      // 非管理空间通道（普通恢复）→ 忽略
    }
  }

  void _openCacheManage() {
    appRouter.push(AppRoute.cacheManage);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
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
