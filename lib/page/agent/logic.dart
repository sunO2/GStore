import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gstore/core/agent/agent_service.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/router/app_router.dart';

import 'state.dart';

/// AI 助手页控制器（Riverpod Notifier）。
///
/// 持有页面级 UI 物（输入框/滚动/焦点）与对 [AgentService] 的桥接：
/// - 订阅 service.busy → isGenerating（生成状态由服务层驱动，页面退出不影响执行）
/// - 订阅 service.messages → 流式输出自动滚底（分页时跳过）
/// 服务实例经 ModuleManager 懒取（模块热插拔，下线返回 null → 页面降级）。
class AgentNotifier extends AutoDisposeNotifier<AgentState> {
  final TextEditingController inputController = TextEditingController();
  final FocusNode inputFocusNode = FocusNode();
  final ScrollController scrollController = ScrollController();

  /// 是否已完成初始加载（初始化加载历史消息时不触发滚动跳动）
  bool _initialLoaded = false;

  /// 滚动 debounce（dispose 取消）
  Timer? _scrollDebounce;

  /// 是否正在加载更早历史（去重）
  bool _loadingHistory = false;

  /// service 订阅句柄（dispose 取消，防泄漏）
  final List<VoidCallback> _serviceListeners = [];

  /// Agent 服务（每次从模块注册表取，避免模块运行中切换后的过期引用；
  /// agent_tools 模块下线后返回 null → 消费方降级）
  AgentService? get service => ModuleManager.instance.get<AgentService>();

  /// Agent 模块是否未启用（服务未注册）
  bool get agentUnavailable => service == null;

  /// 是否已释放（async 回调后写 state 前检查，避免写已销毁 provider）
  bool _disposed = false;

  @override
  AgentState build() {
    // 生命周期清理（UI 物 + 订阅）
    ref.onDispose(() {
      _disposed = true;
      _scrollDebounce?.cancel();
      for (final l in _serviceListeners) {
        l();
      }
      _serviceListeners.clear();
      inputController.dispose();
      inputFocusNode.dispose();
      scrollController.dispose();
    });

    // 首帧初始化（onReady 语义）：订阅 + 初始化
    Future.microtask(() {
      if (!_disposed) _init();
    });
    return const AgentState();
  }

  /// 初始化 Agent（首帧 + 设置返回后重载）
  Future<void> _init() async {
    final svc = service;
    if (svc == null) {
      // 模块未启用：降级提示，不抛异常
      state = state.copyWith(
        isInitialized: false,
        errorMessage: 'Agent 模块未启用',
      );
      _initialLoaded = true;
      return;
    }
    // 订阅生成状态（幂等：仅首帧注册）
    if (_serviceListeners.isEmpty) {
      // 生成状态由服务层驱动（页面退出不影响执行，重进自动恢复）
      _serviceListeners.add(() => svc.busy.removeListener(_onBusyChanged));
      svc.busy.addListener(_onBusyChanged);
      _onBusyChanged();

      // 消息变化 → 流式时滚底（分页加载历史时跳过）
      _serviceListeners.add(() => svc.messages.removeListener(_onMessagesChanged));
      svc.messages.addListener(_onMessagesChanged);
    }

    final ok = await svc.initialize();
    if (_disposed) return;
    state = state.copyWith(isInitialized: ok, errorMessage: '');
    // 初始化加载完成后允许后续滚动
    _initialLoaded = true;
    // 进入页面显示最新消息（滚动到底部，列表就绪后执行）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToBottom();
    });
  }

  void _onBusyChanged() {
    final svc = service;
    if (svc == null) return;
    state = state.copyWith(isGenerating: svc.busy.value);
  }

  void _onMessagesChanged() {
    final svc = service;
    if (svc == null) return;
    // 同步消息条数（页面据此重建空态/欢迎页）
    state = state.copyWith(messageCount: svc.messages.value.length);
    if (svc.isPaginatingHistory) return;
    _scrollToBottom();
  }

  /// 确保 Agent 已初始化（用于会话列表等需要存储已加载的场景）
  Future<void> ensureInitialized() async {
    final svc = service;
    if (svc == null || svc.sessionStore == null) {
      await _init();
    }
  }

  /// 发送消息（fire-and-forget：执行在 AgentService 全局层，退出页面不中断；
  /// isGenerating 由订阅 service.busy 驱动，不再 await chat 后写本地 state）
  void sendMessage() {
    final text = inputController.text.trim();
    if (text.isEmpty) return;

    final svc = service;
    if (svc == null) {
      state = state.copyWith(errorMessage: 'Agent 模块未启用');
      return;
    }

    inputController.clear();
    unawaited(svc.chat(text));
  }

  /// 发送指定文本（供 AiChatWidget.onSendMessage 使用）
  void sendText(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;

    final svc = service;
    if (svc == null) {
      state = state.copyWith(errorMessage: 'Agent 模块未启用');
      return;
    }

    inputController.clear();
    unawaited(svc.chat(trimmed));
  }

  /// 新建会话
  Future<void> newSession() async {
    final svc = service;
    if (svc == null) {
      state = state.copyWith(errorMessage: 'Agent 模块未启用');
      return;
    }
    await svc.newSession();
    _scrollToBottom();
  }

  /// 切换会话
  Future<void> switchSession(String id) async {
    final svc = service;
    if (svc == null) {
      state = state.copyWith(errorMessage: 'Agent 模块未启用');
      return;
    }
    await svc.switchSession(id);
    _scrollToBottom();
  }

  /// 删除会话
  Future<void> deleteSession(String id) async {
    final svc = service;
    if (svc == null) {
      state = state.copyWith(errorMessage: 'Agent 模块未启用');
      return;
    }
    await svc.deleteSession(id);
    AppDialogs.showSuccess('对话已删除');
  }

  /// 清空当前会话
  Future<void> clearCurrentSession() async {
    final svc = service;
    if (svc == null) {
      state = state.copyWith(errorMessage: 'Agent 模块未启用');
      return;
    }
    await svc.clearCurrentSession();
    AppDialogs.showSuccess('当前对话已清空');
  }

  /// 当前使用的模型显示名
  String get currentModelName {
    final model = service?.model;
    if (model == null) return '';
    return '${model.provider == AgentLlmProvider.google ? 'Gemini' : 'OpenAI'} · ${model.effectiveModel}';
  }

  /// 打开设置
  Future<void> openSettings() async {
    await appRouter.push(AppRoute.agentSettings);
    // 返回后重新加载配置并初始化（配置可能已变化）
    await _init();
  }

  /// 滚动到底部（普通列表，底部 = maxScrollExtent）
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
}

/// AI 助手页 provider（页面级 autoDispose：
/// 页面挂载时被 watch 创建，独立路由 pop / 页面销毁后自动释放
/// 控制器与订阅；作为首页 tab keepAlive 时切走不销毁，状态保留）。
final agentProvider =
    NotifierProvider.autoDispose<AgentNotifier, AgentState>(
  AgentNotifier.new,
);
