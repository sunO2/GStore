import 'package:get/get.dart';
import 'package:gstore/core/agent/agent_service.dart';

class AgentState {
  /// 是否正在生成
  final RxBool isGenerating = false.obs;

  /// 是否已初始化（已配置 API Key）
  final RxBool isInitialized = false.obs;

  /// 降级提示（Agent 模块未启用等）
  final RxString errorMessage = ''.obs;

  /// 对话消息
  final RxList<AgentMessage> messages = <AgentMessage>[].obs;

  AgentState() {
    ///Initialize variables
  }
}
