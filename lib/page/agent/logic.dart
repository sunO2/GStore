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

  /// 本次手指手势在屏幕上累计滑动的距离（px）
  double _dragAccum = 0;

  /// 按下时的滚动偏移（用于判断"列表到底动没动"）
  double? _pixelsAtDown;

  /// 用户是否已通过手势主动上翻阅读。
  ///
  /// 只由手势决定（手指真移动了 **且** 列表真滚动了），不看单纯的位置 ——
  /// 位置会被内容增长/漂移带偏；点按、长按、在列表尽头空拖都不会误置位。
  bool _userScrolledAway = false;

  /// 用户是否已主动上翻阅读（手势判定，见 [onPointerUp]）
  bool get userScrolledAway => _userScrolledAway;

  /// 手指是否正按在屏幕上（用于滚动期间禁用位置补偿，避免与手势互搏）
  bool get pointerActive => _pointerActive;

  // 手势进行中标志：手指按下后置 true，抬起/取消后置 false。
  // 滚动动画（惯性、库动画）期间也视为活跃，避免补偿与手势/动画互搏。
  bool _pointerActive = false;

  /// **流式 UI 挂起标志**（三态状态机，见 onPointerUp）。
  ///
  /// 用户交互期间（手指按下/滑动阅读）置 true → 消息列表收到 chunk 只更新
  /// 数据不重建 UI（内容冻结，读历史零打扰）；松手按位置三路判定：
  /// - 点按（未滑动）→ 立即恢复；
  /// - 回到底部附近 → 恢复 + 主动 jumpTo(0) 贴底（积攒内容一次性出现）；
  /// - 停在历史中间 → 保持挂起，滚动回底部时才恢复。
  bool _uiPaused = false;

  /// 流式 UI 是否处于挂起态（消息列表据此跳过 setState 冻结 UI）
  bool get uiPaused => _uiPaused;

  /// 设置挂起态（供 view 层同步触发重建；state 不入 AgentState，
  /// 由 view 的 Listener 手势回调里 setState 重建 AgentChatListView）
  void _setUiPaused(bool paused) {
    if (_uiPaused == paused) return;
    _uiPaused = paused;
  }

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
    // 非强制：用户已上翻阅读历史时不抢滚动，改为钉住当前阅读位置
    _scrollToBottom(force: false);
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
    _submitAndJumpBottom(() => svc.chat(text));
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
    _submitAndJumpBottom(() => svc.chat(trimmed));
  }

  /// 统一发送路径：先解除挂起（用户在历史中间挂起时发消息，必须恢复 UI
  /// 更新和跟随），再执行发送并回到底部——否则滚底 Timer 的双保险会因
  /// _uiPaused 而取消 jumpTo(0)，发完消息停在上翻位置。
  void _submitAndJumpBottom(Future<void> Function() send) {
    // 解除挂起：发消息 = 主动回到当前对话，冻结状态作废
    _setUiPaused(false);
    _userScrolledAway = false;
    // 取消上一次手势遗留的滚底 debounce，避免与本次跳转竞争的时序抖动
    _scrollDebounce?.cancel();
    _scrollDebounce = null;
    unawaited(send());
    // 自己发消息：无条件回到底部（即使刚在上翻阅读）
    _scrollToBottom();
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

  /// 滚动到底部（库使用 reverse 列表，offset 0 = 视觉底部/最新消息）。
  ///
  /// [force] = true：无条件滚底。用于进入页面、新建/切换会话、自己发消息
  /// 这些"必须看到最新"的场景，并会清除"用户已上翻"标记。
  ///
  /// [force] = false（消息流式更新）：用户已通过手势上翻阅读时就**完全不碰
  /// 滚动**（原来是无条件 jumpTo(0)，会把正在读历史的人硬拽回底部）；
  /// 一旦用户回到最底部（或从未上翻）则恢复跟随。
  void _scrollToBottom({bool force = true}) {
    if (!_initialLoaded) return;

    // 手指正按在屏幕上（用户正在滑动/拖动）→ 完全不干预滚动。
    // 此时 `_userScrolledAway` 还需等 onPointerUp 才判定（滑动中恒为 false），
    // 若此刻流式 chunk 到达按旧逻辑 schedule jumpTo(0)，会把正滑到一半的
    // 人硬拽回底部；贴底反拖、上翻挣扎都是这样产生的。
    if (!force && _pointerActive) return;

    if (force) {
      _userScrolledAway = false;
    } else if (!shouldFollowOutput(
      userScrolledAway: _userScrolledAway,
      pixels: scrollController.hasClients
          ? scrollController.position.pixels
          : 0,
    )) {
      return;
    } else {
      // 已回到最底部 → 恢复跟随
      _userScrolledAway = false;
    }

    // reverse 列表 offset 0 = 视觉底部 = 内容底部：**贴底时新增内容天然
    // 从底部平滑长出（列表自动保持 offset 0，无需任何滚动干预）**。
    // 所以仅当确实偏离底部（force 滚底场景除外）才需要 jumpTo(0) 拉回，
    // 否则每次流式 chunk 都 schedule 一次强制滚动，反而与增长竞争产生跳动。
    if (!force && _hasClients && scrollController.position.pixels <= kScrollDragSlop) {
      return;
    }

    _scrollDebounce?.cancel();
    _scrollDebounce = Timer(const Duration(milliseconds: 80), () {
      // 双保险：pending 滚底在执行时若用户已按下/挂起 → 取消。
      // 防"松手滚底 80ms 内又上翻，Timer 把正滑的人拽回"。
      //
      // **不用 addPostFrameCallback**：静止状态（无动画/无 setState）下
      // 没有新帧被调度，postFrame 回调永远挂起 → jumpTo 永不执行。
      // Timer 本身已提供延迟，直接跳即可（jump 对布局无强依赖）。
      if (_pointerActive || _uiPaused) return;
      if (_initialLoaded && scrollController.hasClients &&
          scrollController.position.pixels > kScrollDragSlop) {
        scrollController.jumpTo(0);
      }
    });
  }

  // -------------------------------------------------------------------------
  // 手势：判断"用户是在翻阅历史，还是只是点了一下"
  // -------------------------------------------------------------------------

  /// 手指按下：重置本次手势的累计，记下当前滚动位置，并**挂起流式 UI**。
  ///
  /// 挂起期间消息列表收到 chunk 只更新数据不重建（内容冻结），
  /// 用户滑动阅读历史时不会被最新消息的持续增长打扰。
  void onPointerDown() {
    _pointerActive = true;
    _dragAccum = 0;
    _pixelsAtDown = _hasClients ? scrollController.position.pixels : null;
    // 取消 pending 滚底 debounce（上一次松手触发的 force 滚底 80ms 后本会
    // jumpTo(0)，用户又按下开始新操作 → 该意图作废，绝不在新滑动中拽回）
    _scrollDebounce?.cancel();
    _scrollDebounce = null;
    _setUiPaused(true);
  }

  /// 手指移动：累计滑动距离（多段小位移也会累加）
  void onPointerMove(Offset delta) {
    _dragAccum += delta.distance;
  }

  /// 手指抬起/取消：按"手势方向 + 是否真的滚动了"决定跟随状态，
  /// 并**按松手位置决定流式 UI 挂起是否解除**（三态状态机）。
  ///
  /// 判定要求 **手指真移动了** 且 **列表真滚动了**：
  /// - 点按 / 长按（含手指轻微抖动）→ 列表没动 → 不改状态；
  /// - 在列表尽头空拖（已经贴底还往下拽）→ 无位移 → 不改状态。
  ///
  /// 通过后按方向处理：
  /// - 往上翻（pixels 变大，离开底部）→ 关闭自动跟随；
  /// - 往下翻且已经回到最底部附近（≤ [kReattachTolerance]）→ 恢复自动跟随；
  /// - 往下翻但停在历史中间 → 维持现状（还在读历史）。
  ///
  /// 挂起解除（_uiPaused）三路：
  /// - 未滑动（点按/长按）→ 立即恢复（复制/选中不受影响）；
  /// - 松手时**在底部附近**（≤ [kReattachTolerance]，无论上翻/下翻）→
  ///   解除挂起恢复正常更新；方向为**下翻**（delta < 0，明确回身看最新）→
  ///   主动贴底展示积攒内容；方向为上翻（delta > 0，轻轻看了一眼）→
  ///   解除挂起但**保留位置**（userScrolledAway=true）——否则下一个流式
  ///   chunk 走 force:false 跟随会把用户拽回底部（"一滑动就跳回 0"）；
  /// - 松手在历史中间（pixels > [kReattachTolerance]）→ 保持挂起，
  ///   滚动回底部才恢复。
  void onPointerUp() {
    final moved = _dragAccum > kScrollDragSlop;
    final atDown = _pixelsAtDown;
    final delta = (_hasClients && atDown != null)
        ? scrollController.position.pixels - atDown
        : 0.0;
    final scrolled = delta.abs() > kScrollDragSlop;
    final nearBottom =
        _hasClients && scrollController.position.pixels <= kReattachTolerance;

    // 跟随状态（userScrolledAway）：只有真正滑进历史深处（> 容差）才关闭
    // 自动跟随；底部附近轻轻滑动视为"保留了位置"（不自动跟随，避免被
    // 下一次 chunk 拽回）。方向为下翻回底则恢复跟随。
    if (moved && scrolled) {
      if (delta > 0 && !nearBottom) {
        _userScrolledAway = true; // 上翻进入历史 → 读历史，关闭跟随
      } else if (delta > 0 && nearBottom) {
        _userScrolledAway = true; // 上翻停在底部附近 → 保留位置（防拽回）
      } else if (delta < 0 && nearBottom) {
        _userScrolledAway = false; // 下翻回底 → 恢复跟随
      }
    }

    // 三态判定：按松手最终位置决定挂起是否解除。
    if (!moved || !scrolled) {
      // 点按/长按/尽头空拖：未真正阅读 → 立即恢复
      _setUiPaused(false);
    } else if (nearBottom) {
      // 松手在底部附近：解除挂起恢复正常更新
      _setUiPaused(false);
      if (delta < 0) {
        // 下翻回底部（明确回来看最新）→ 贴底，积攒内容一次性出现
        _userScrolledAway = false;
        _scrollToBottom(force: true);
      }
      // 上翻停在底部附近（delta > 0）：已无挂起但保留位置（上面的判定
      // 已置 userScrolledAway=true），后续 chunk 不拽回；用户下滑即恢复
    }
    // 松手在历史中间（pixels > kReattachTolerance）：保持挂起，
    // 滚动回底部（resumeUiPauseIfNearBottom）才恢复。

    _dragAccum = 0;
    _pixelsAtDown = null;
    _pointerActive = false;
  }

  /// 手指取消（系统中断）：解除挂起（否则 UI 永久冻结）。
  /// 与 onPointerUp 的"点按恢复"路径一致——系统中断时不做跳转判定，
  /// 只是让 UI 恢复更新（用户位置不动，积攒内容自然渲染）。
  void onPointerCancel() {
    _dragAccum = 0;
    _pixelsAtDown = null;
    _pointerActive = false;
    _setUiPaused(false);
  }

  /// **公开恢复入口**：滚动回到底部附近（≤ [kReattachTolerance]）时由
  /// 页面滚动监听调用，解除挂起并恢复跟随。这是"停在历史中间松手"场景的
  /// 补充恢复路径——用户滚回底部即看到积攒的最新内容。
  ///
  /// **只解除挂起、不强制 jumpTo(0)**：滚动监听在惯性滚动/回弹（Bouncing）
  /// 期间也会触发，若这里主动 jumpTo(0) 会把经过底部区域的任何滚动强拽回
  /// 底部——"一滑动就跳回 0（输出结束也如此）"的根因。解除挂起后：
  /// - 若在流式中：后续 `_scrollToBottom(force:false)` 看到 offset ≤48 且 >5
  ///   会自动贴底（用户在底部 → follow）；
  /// - 若输出已结束：用户本就在底部附近，无需强制贴底。
  void resumeUiPauseIfNearBottom() {
    if (!_uiPaused) return;
    if (_pointerActive) return; // 手指正按着（滑动中）→ 不打断
    if (!_hasClients) return;
    if (scrollController.position.pixels <= kReattachTolerance) {
      _setUiPaused(false);
      _userScrolledAway = false;
      // 不 jumpTo(0)：交给流式增量的正常跟随（force:false），
      // 避免惯性/回弹经过底部被强拽。
    }
  }

  /// **回到最新（按钮显式触发）**：无条件解除挂起、恢复跟随并滚到底部。
  ///
  /// 与 [resumeUiPauseIfNearBottom]（滚动监听的被动恢复，不强制跳）不同，
  /// 这是用户点击"回到底部"按钮的显式意图——无论当前停在历史哪里、
  /// 是否挂起，都回到最新消息并展示积攒的内容。
  ///
  /// **不用 debounce + postFrameCallback**：它们是给"自动滚底"（流式 chunk
  /// 高频触发）防抖用的；按钮点击是离散单次操作，且静止状态下页面无新帧
  /// 被调度 → postFrameCallback 永不触发 → jumpTo 永远不执行（用户看到的
  /// "滑动状态有效、静止状态点击无效"的根因）。这里直接 jumpTo(0) 立即生效。
  void jumpToLatest() {
    _setUiPaused(false);
    _userScrolledAway = false;
    _scrollDebounce?.cancel();
    _scrollDebounce = null;
    if (_hasClients) {
      scrollController.jumpTo(0);
    }
  }

  bool get _hasClients => scrollController.hasClients;

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

// ---------------------------------------------------------------------------
// 滚动策略（纯函数，便于单测）
// ---------------------------------------------------------------------------

/// 手势滑动判定阈值（px）。
///
/// 手指累计滑动**超过**它、且列表**真的滚动了**超过它，才算"用户主动滑动"；
/// 点按 / 长按（列表没跟着动）不算，不会把自动跟随关掉。
const double kScrollDragSlop = 5;

/// 下翻时"已经回到最底部"的判定容差（px）。
///
/// 手指往**下滑**并且停在距底部这么近的位置 → 视为回到最新，恢复自动跟随。
/// 只在下翻方向生效，所以给得宽松也不会造成"往上滑一点点就被拽回底部"。
const double kReattachTolerance = 48;

/// 流式输出是否应该自动跟随到底部。
///
/// - [userScrolledAway]：用户是否已主动上翻阅读（见 [kScrollDragSlop]）
/// - [pixels]：reverse 列表当前偏移，0 = 最底部
///
/// 规则：用户没主动上翻 → 跟随；已上翻 → 不跟随，除非已经**真正回到最底部**
/// （容差 [kScrollDragSlop]；同时 [AgentNotifier] 在判定到这一点时会清掉
/// "已上翻"标记，所以回到最新后会自动恢复跟随）。
bool shouldFollowOutput({
  required bool userScrolledAway,
  required double pixels,
}) =>
    !userScrolledAway || pixels <= kScrollDragSlop;

// 交互策略（与页面 view 的天然行为一致，简单可靠）：
// - 跟随态（用户没上翻）→ 消息变化即滚底，流式输出保持可见；
// - 上翻阅读态 → **完全不干预滚动/不做位置补偿**，新内容把已读内容自然
//   往上推（微信/Telegram 等聊天应用一致的行为），用户滑回底部附近即
//   自动恢复跟随（见 [kReattachTolerance]）。
// 为什么不做"破解内容推移的锚定/补偿"：
//   1. 切换前实现过 GlobalKey 锚点 + jumpTo 位移补偿的方案，实测在流式
//      高频增长下与库的自动滚动动画互相拉扯，表现为持续跳动；
//   2. reverse 懒加载列表的 maxScrollExtent 是估算值，按它补偿会过冲/漏补；
//   3. 聊天主流程（读历史时不被打断）在不补偿时体验已达标，微信类产品
//      从不补偿就是这个原因。
