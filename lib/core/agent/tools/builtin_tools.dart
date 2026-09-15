/// 内置 Agent 工具模块（由协议注册表自动派生）
///
/// 元数据（名称/描述/参数）不再在此重复声明，统一来自
/// `agent_tool_spec.dart` 的 [AgentToolCatalog]（单一事实来源）：
/// - 系统提示词目录、function-calling 描述、AiAction 参数、敏感清单
///   全部由注册表生成，避免多处硬编码漂移
/// - 每个内置工具仍以 [AgentToolModule] 形式参与模块上下线（热插拔）
///
/// 新增工具只需在 [kBuiltinToolSpecs] 增加一条协议声明，本文件无需改动。
library;

import '../agent_tool_module.dart';
import '../agent_tool_spec.dart';

/// 由协议声明派生的工具模块
class SpecBackedTool extends AgentToolModule {
  SpecBackedTool(this.spec);

  final AgentToolSpec spec;

  @override
  String get toolName => spec.name;

  @override
  String get toolDescription => spec.brief;

  @override
  List<AgentToolParam> get toolParams => spec.params;

  @override
  bool get enabled => spec.enabled;

  @override
  String get moduleName => 'agent_tool_${spec.name}';
}

/// 内置工具注册表（AgentService 初始化时注册全部内置工具）
class BuiltinAgentTools {
  BuiltinAgentTools._();

  /// 全部内置工具模块（不含元能力工具 toolProtocol —— 它由 AgentService 内部实现）
  static List<AgentToolModule> get all => AgentToolCatalog.all
      .where((s) => !s.meta)
      .map((s) => SpecBackedTool(s))
      .toList();
}
