/// 模块抽象与模块上下文
library;

import '../config/config_service.dart';

/// 模块上下文
///
/// 提供给 [AppModule.onRegister]/[AppModule.onUnregister]，
/// 用于模块上下线时联动注册/注销配置、Agent 工具与服务接口。
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

  ModuleContext({
    this.config,
    this.registerAgentTools,
    this.unregisterAgentTools,
    this.bindService,
    this.unbindService,
  });
}

/// 应用模块抽象
///
/// 模块上线注册到 [ModuleManager]，下线移除；上下线时通过
/// [onRegister]/[onUnregister] 联动管理配置（ConfigModule）、
/// Agent 工具与服务接口，实现热插拔。
abstract class AppModule {
  /// 模块名（唯一标识）
  String get moduleName;

  /// 加载优先级（数字越小越先注册）
  int get priority => 100;

  /// 上线钩子：注册配置、Agent 工具、服务接口
  Future<void> onRegister(ModuleContext context) async {}

  /// 下线钩子：注销配置、Agent 工具、服务接口
  Future<void> onUnregister(ModuleContext context) async {}
}
