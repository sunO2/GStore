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

  /// Agent 服务（每次从模块注册表取，避免模块运行中切换后的过期引用；
  /// agent_tools 模块下线后返回 null → 消费方降级）
  AgentService? get service => ModuleManager.instance.get<AgentService>();

  /// Agent 模块是否未启用（服务未注册）
  bool get agentUnavailable => service == null;

  @override
  void onReady() async {
    super.onReady();

    // 监听消息变化，流式输出时自动滚动到底部
    // 分页加载历史时跳过（避免加载更多后跳回底部）
    final svc = service;
    if (svc != null) {
      svc.messages.listen((_) {
        if (svc.isPaginatingHistory) return;
        _scrollToBottom();
      });
    }

    await _init();
  }

  /// 初始化 Agent
  Future<void> _init() async {
    final svc = service;
    if (svc == null) {
      // 模块未启用：降级提示，不抛异常
      state.isInitialized.value = false;
      state.errorMessage.value = 'Agent 模块未启用';
      _initialLoaded = true;
      return;
    }
    final ok = await svc.initialize();
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
    final svc = service;
    if (svc == null || svc.sessionStore == null) {
      await _init();
    }
  }

  /// 发送消息
  Future<void> sendMessage() async {
    final text = inputController.text.trim();
    if (text.isEmpty) return;

    final svc = service;
    if (svc == null) {
      state.errorMessage.value = 'Agent 模块未启用';
      return;
    }

    inputController.clear();
    state.isGenerating.value = true;

    await svc.chat(text);

    state.isGenerating.value = false;
    _scrollToBottom();
  }

  /// 发送指定文本（供 AiChatWidget.onSendMessage 使用）
  Future<void> sendText(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;

    final svc = service;
    if (svc == null) {
      state.errorMessage.value = 'Agent 模块未启用';
      return;
    }

    inputController.clear();
    state.isGenerating.value = true;

    await svc.chat(trimmed);

    state.isGenerating.value = false;
    _scrollToBottom();
  }

  /// 新建会话
  Future<void> newSession() async {
    final svc = service;
    if (svc == null) {
      state.errorMessage.value = 'Agent 模块未启用';
      return;
    }
    await svc.newSession();
    _scrollToBottom();
  }

  /// 切换会话
  Future<void> switchSession(String id) async {
    final svc = service;
    if (svc == null) {
      state.errorMessage.value = 'Agent 模块未启用';
      return;
    }
    await svc.switchSession(id);
    _scrollToBottom();
  }

  /// 删除会话
  Future<void> deleteSession(String id) async {
    final svc = service;
    if (svc == null) {
      state.errorMessage.value = 'Agent 模块未启用';
      return;
    }
    await svc.deleteSession(id);
    Get.snackbar('已删除', '对话已删除',
        snackPosition: SnackPosition.BOTTOM,
        duration: const Duration(seconds: 1));
  }

  /// 清空当前会话
  Future<void> clearCurrentSession() async {
    final svc = service;
    if (svc == null) {
      state.errorMessage.value = 'Agent 模块未启用';
      return;
    }
    await svc.clearCurrentSession();
    Get.snackbar('已清空', '当前对话已清空',
        snackPosition: SnackPosition.BOTTOM,
        duration: const Duration(seconds: 1));
  }

  /// 当前使用的模型显示名
  String get currentModelName {
    final model = service?.model;
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
  /// 库使用 reverse 列表（reverseOrder=true），offset 0 = 视觉底部（最新消息）
  /// jumpTo(0) 无动画跳动；初始化加载历史消息阶段跳过，避免进入页面时跳动
  void _scrollToBottom() {
    if (!_initialLoaded) return;
    _scrollDebounce?.cancel();
    _scrollDebounce = Timer(const Duration(milliseconds: 80), () {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (scrollController.hasClients) {
          scrollController.jumpTo(0);
        }
      });
    });
  }

  /// 滚动到顶部时加载更早的历史消息（保持当前视觉位置不跳动）
  void loadMoreHistoryIfNeeded() {
    final svc = service;
    if (svc == null) return;
    if (!svc.hasMoreHistory) return;
    if (_loadingHistory) return;
    _loadingHistory = true;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (scrollController.hasClients) {
        // 记录加载前的偏移量
        final oldPixels = scrollController.position.pixels;

        svc.loadMoreHistory();

        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (scrollController.hasClients) {
            // reverse 列表：offset 0 = 底部（最新），maxScrollExtent = 顶部（最早）。
            // 更早消息插入数组开头 = 视觉顶部，offset 不变即可保持当前视觉位置。
            scrollController.jumpTo(oldPixels.clamp(
              0.0,
              scrollController.position.maxScrollExtent,
            ));
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
