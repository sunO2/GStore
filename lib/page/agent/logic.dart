import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:gstore/core/agent/agent_service.dart';
import 'package:gstore/core/core.dart';

import 'state.dart';

class AgentLogic extends GetxController {
  final AgentState state = AgentState();

  final TextEditingController inputController = TextEditingController();
  final FocusNode inputFocusNode = FocusNode();
  final ScrollController scrollController = ScrollController();

  /// Agent 服务
  AgentService? _service;

  AgentService get service {
    _service ??= Get.find<AgentService>();
    return _service!;
  }

  @override
  void onReady() async {
    super.onReady();

    // 监听消息变化，流式输出时自动滚动到底部
    service.messages.listen((_) {
      _scrollToBottom();
    });

    await _init();
  }

  /// 初始化 Agent
  Future<void> _init() async {
    final ok = await service.initialize();
    state.isInitialized.value = ok;
  }

  /// 确保 Agent 已初始化（用于会话列表等需要存储已加载的场景）
  Future<void> ensureInitialized() async {
    if (service.sessionStore == null) {
      await _init();
    }
  }

  /// 发送消息
  Future<void> sendMessage() async {
    final text = inputController.text.trim();
    if (text.isEmpty) return;

    inputController.clear();
    state.isGenerating.value = true;

    await service.chat(text);

    state.isGenerating.value = false;
    _scrollToBottom();
  }

  /// 新建会话
  Future<void> newSession() async {
    await service.newSession();
    _scrollToBottom();
  }

  /// 切换会话
  Future<void> switchSession(String id) async {
    await service.switchSession(id);
    _scrollToBottom();
  }

  /// 删除会话
  Future<void> deleteSession(String id) async {
    await service.deleteSession(id);
    Get.snackbar('已删除', '对话已删除',
        snackPosition: SnackPosition.BOTTOM,
        duration: const Duration(seconds: 1));
  }

  /// 清空当前会话
  Future<void> clearCurrentSession() async {
    await service.clearCurrentSession();
    Get.snackbar('已清空', '当前对话已清空',
        snackPosition: SnackPosition.BOTTOM,
        duration: const Duration(seconds: 1));
  }

  /// 当前使用的模型显示名
  String get currentModelName {
    final model = service.model;
    if (model == null) return '';
    return '${model.provider == AgentLlmProvider.google ? 'Gemini' : 'OpenAI'} · ${model.effectiveModel}';
  }

  /// 打开设置
  Future<void> openSettings() async {
    await Get.toNamed(AppRoute.agentSettings);
    // 返回后重新加载配置并初始化（配置可能已变化）
    await _init();
  }

  /// 滚动到底部
  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (scrollController.hasClients) {
        scrollController.animateTo(
          scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  void onClose() {
    inputController.dispose();
    inputFocusNode.dispose();
    scrollController.dispose();
    super.onClose();
  }
}
