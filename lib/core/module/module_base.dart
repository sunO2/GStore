/// 模块抽象与模块上下文
library;

import '../config/config_service.dart';
import 'module_manager.dart';

/// 模块上下文
///
/// 提供给 [AppModule.onInit]/[AppModule.onRegister]/[AppModule.onUnregister]，
/// 用于模块上下线时联动注册/注销配置、Agent 工具与服务接口，
/// 以及从 ModuleManager 获取依赖服务。
class ModuleContext {
  /// 统一配置服务（可能为 null：未初始化或测试环境）
  final ConfigService? config;

  /// Agent 工具注册器（由 AgentService 注入）
  final void Function(List<dynamic> tools)? registerAgentTools;

  /// Agent 工具注销器（由 AgentService 注入）
  final void Function(List<String> toolNames)? unregisterAgentTools;

  /// 服务接口绑定（Type → 实现）
  final void Function(Type type, Object impl)? bindService;

  /// 服务接口解绑
  final void Function(Type type)? unbindService;

  /// 模块管理器引用（获取依赖服务）
  final ModuleManager? manager;

  ModuleContext({
    this.config,
    this.registerAgentTools,
    this.unregisterAgentTools,
    this.bindService,
    this.unbindService,
    this.manager,
  });

  /// 获取依赖服务（未注册抛异常，用于 serviceDependencies 声明后取用）
  T requireDependency<T>() {
    final m = manager;
    if (m == null) {
      throw StateError('ModuleContext 未注入 manager，无法获取依赖 $T');
    }
    return m.require<T>();
  }
}

/// 应用模块抽象
///
/// 模块上线注册到 [ModuleManager]，下线移除。
/// 模块通过 [dependencies]/[serviceDependencies] 声明依赖，
/// 由 ModuleManager 拓扑排序后按依赖顺序初始化（类似 Linux 包管理器）：
/// 1. 依赖模块全部初始化完成
/// 2. 调用本模块 [onInit]（自身初始化：建库/启动服务/GetX 注册）
/// 3. 调用本模块 [onRegister]（绑定配置/工具/服务接口）
abstract class AppModule {
  /// 模块名（唯一标识）
  String get moduleName;

  /// 依赖的模块名（必须先于本模块初始化）
  List<String> get dependencies => const [];

  /// 依赖的服务类型（初始化后可通过 ModuleManager.get<T>() 获取）
  List<Type> get serviceDependencies => const [];

  /// 加载优先级（同层内排序，数字越小越先；弱于依赖关系）
  int get priority => 100;

  /// 自身初始化（依赖就绪后执行：建库/启动服务/GetX 注册）
  Future<void> onInit(ModuleContext context) async {}

  /// 初始化完成后绑定配置/工具/服务接口（依赖就绪后执行）
  Future<void> onRegister(ModuleContext context) async {}

  /// 下线钩子：注销配置、Agent 工具、服务接口
  Future<void> onUnregister(ModuleContext context) async {}
}
