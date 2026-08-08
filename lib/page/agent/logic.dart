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

  /// 是否已完成初始加载（初始化加载历史消息时不触发滚动跳动）
  bool _initialLoaded = false;

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
    // 初始化加载完成后允许后续滚动
    _initialLoaded = true;
    // 进入页面显示最新消息（滚动到底部，列表就绪后执行）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToBottom();
    });
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

  /// 发送指定文本（供 AiChatWidget.onSendMessage 使用）
  Future<void> sendText(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;

    inputController.clear();
    state.isGenerating.value = true;

    await service.chat(trimmed);

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

  /// 滚动到底部（普通列表，底部 = maxScrollExtent）
  Timer? _scrollDebounce;

  /// 滚动到底部
  /// 普通列表用 jumpTo(maxScrollExtent) 滚到最新消息，无动画跳动；
  /// 初始化加载历史消息阶段跳过，避免进入页面时跳动
  void _scrollToBottom() {
    if (!_initialLoaded) return;
    _scrollDebounce?.cancel();
    _scrollDebounce = Timer(const Duration(milliseconds: 80), () {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (scrollController.hasClients) {
          scrollController.jumpTo(scrollController.position.maxScrollExtent);
        }
      });
    });
  }

  /// 滚动到顶部时加载更早的历史消息（保持当前视觉位置不跳动）
  void loadMoreHistoryIfNeeded() {
    if (!service.hasMoreHistory) return;
    if (_loadingHistory) return;
    _loadingHistory = true;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (scrollController.hasClients) {
        // 记录加载前的偏移量
        final oldMax = scrollController.position.maxScrollExtent;
        final oldPixels = scrollController.position.pixels;

        service.loadMoreHistory();

        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (scrollController.hasClients) {
            // 普通列表：新内容插入顶部，maxScrollExtent 增大，
            // 补偿偏移量保持视觉位置不变（内容下移量 = 新增滚动范围）
            final newMax = scrollController.position.maxScrollExtent;
            final delta = newMax - oldMax;
            if (delta > 0) {
              scrollController.jumpTo(oldPixels + delta);
            }
          }
          _loadingHistory = false;
        });
      } else {
        _loadingHistory = false;
      }
    });
  }

  bool _loadingHistory = false;

  @override
  void onClose() {
    _scrollDebounce?.cancel();
    inputController.dispose();
    inputFocusNode.dispose();
    scrollController.dispose();
    super.onClose();
  }
}
