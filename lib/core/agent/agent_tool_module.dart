/// Agent 工具模块化抽象
///
/// 每个 Agent 工具（searchApp/downloadApp/...）独立为一个 [AgentToolModule]，
/// 通过 ModuleManager 注册（上线）与注销（下线）：
/// - 上线：注册到 AgentService 的工具清单（defineTool + AiAction）
/// - 下线：从 AgentService 工具清单移除，模型不再能调用
///
/// 工具执行逻辑通过 [AgentToolContext] 委托给具体实现，
/// 保持与原有 AgentService 内部工具方法行为一致。
library;

import '../module/module_base.dart';

/// Agent 工具参数定义（供模型函数调用 schema）
class AgentToolParam {
  /// 参数名
  final String name;

  /// 描述（模型理解用途）
  final String description;

  /// 是否必填
  final bool required;

  /// 参数类型（string/int/bool/json）
  final String type;

  const AgentToolParam({
    required this.name,
    required this.description,
    this.required = false,
    this.type = 'string',
  });
}

/// Agent 工具执行上下文
///
/// 提供工具执行所需的环境能力：
/// - [executeDelegate]：实际执行函数（由 AgentService 注入，委托既有实现）
/// - [stopRequested]：是否已请求停止生成（工具应尽早返回）
class AgentToolContext {
  /// 实际执行委托（key → params → 结果文本）
  final Future<String> Function(String toolName, Map<String, dynamic> params)?
      executeDelegate;

  /// 停止请求检查
  final bool Function()? stopRequested;

  const AgentToolContext({
    this.executeDelegate,
    this.stopRequested,
  });

  /// 执行工具调用
  Future<String> execute(String toolName, Map<String, dynamic> params) async {
    final delegate = executeDelegate;
    if (delegate == null) {
      return '工具 $toolName 未注册执行器';
    }
    return delegate(toolName, params);
  }

  /// 是否已请求停止
  bool get cancelled => stopRequested?.call() ?? false;
}

/// Agent 工具模块（可插拔）
///
/// 模块上线时通过 ModuleManager 注册，下线时移除；
/// 工具元数据（名称/描述/参数）用于动态构建模型函数调用 schema。
abstract class AgentToolModule extends AppModule {
  /// 工具名称（如 searchApp）
  String get toolName;

  /// 工具描述（模型理解用途）
  String get toolDescription;

  /// 工具参数列表
  List<AgentToolParam> get toolParams => const [];

  /// 默认模块名 = 工具名（可覆盖）
  @override
  String get moduleName => 'agent_tool_$toolName';

  /// 工具是否默认启用（false 时不注册到模型）
  bool get enabled => true;

  /// 执行工具（默认委托 context 到 AgentService 既有实现）
  Future<String> execute(AgentToolContext context, Map<String, dynamic> params) {
    return context.execute(toolName, params);
  }
}

/// 内置工具注册表（AgentService 初始化时注册全部内置工具）
class AgentToolRegistry {
  AgentToolRegistry._();

  /// 全部内置工具模块
  static List<AgentToolModule> get builtinTools => const [];
}
