import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_gen_ai_chat_ui/flutter_gen_ai_chat_ui.dart'
    hide AgentState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:gstore/core/icons/Icons.dart';
import 'package:gstore/page/home/logic.dart';
import 'package:gstore/core/agent/agent_service.dart';
import 'package:gstore/core/core.dart';

import 'logic.dart';
import 'chat_list_view.dart';

class AgentPage extends ConsumerStatefulWidget {
  /// 是否内嵌在首页 tab（底部有悬浮导航胶囊需避让）；
  /// 独立路由进入（我的页 → AI 助手）时无胶囊，输入栏贴底常规间距
  final bool isTabEmbedded;

  const AgentPage({super.key, this.isTabEmbedded = false});

  @override
  ConsumerState<AgentPage> createState() => _AgentPageState();
}

/// 保持页面状态（作为首页 tab 时切换不销毁：输入/滚动/对话状态保留）
class _AgentPageState extends ConsumerState<AgentPage>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  /// 悬浮输入框焦点（tab 内嵌时离开 AI tab 自动失焦收键盘）
  final FocusNode _inputFocusNode = FocusNode();

  /// 滚动控制器（AgentNotifier 持有；initState 取引用，dispose 时 ref 不可用）
  late final ScrollController _scroll;

  /// 是否正在分页加载（分页时跳过自动滚动，避免跳回底部）
  bool _isPaginating = false;

  /// 是否显示"回到底部"按钮（用户上翻阅读/偏离底部时出现，回底后隐藏）
  bool _showScrollToBottom = false;

  AgentNotifier get _notifier => ref.read(agentProvider.notifier);

  @override
  void initState() {
    super.initState();
    // 独立路由进入：标记 AI 页可见（服务层后台通知/敏感拦截门控）
    if (!widget.isTabEmbedded) {
      HomeTabVisibility.instance.setAgentRoute(true);
    }
    // 触发 AgentNotifier 建立（首帧初始化）
    ref.read(agentProvider);

    // 监听滚动：reverse 列表接近顶部（最早消息）时加载更早历史
    // 自绘列表使用 notifier.scrollController，此处直接监听
    _scroll = _notifier.scrollController;
    _scroll.addListener(_onScrollChanged);

    // tab 内嵌场景：离开 AI tab 自动失焦（收键盘），进入不自动聚焦——由用户点击输入框唤起键盘
    if (widget.isTabEmbedded) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ref.listenManual(homeProvider.select((s) => s.index), (prev, next) {
          if (!mounted) return;
          // 等一帧确保输入框已构建（keepAlive 页输入框常驻，index 变化后立即失焦）
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (next != 2) {
              _inputFocusNode.unfocus();
            }
          });
        });
      });
    }
  }

  /// 滚动位置变化：接近 reverse 列表顶部时加载更早历史；
  /// 偏离底部超过容差时显示"回到底部"按钮，回底隐藏
  void _onScrollChanged() {
    if (!_scroll.hasClients) return;
    final position = _scroll.position;
    // reverse 列表：offset 0 = 底部（最新），maxScrollExtent = 顶部（最早）
    if (position.maxScrollExtent > 0 &&
        position.pixels >= position.maxScrollExtent - 100) {
      debugPrint(
          'AgentView nearTop: pixels=${position.pixels.toStringAsFixed(0)} max=${position.maxScrollExtent.toStringAsFixed(0)}');
      _triggerLoadMore();
    }
    // 挂起态：滚动回到底部附近 → 解除挂起并贴底（补充恢复路径）
    final logic = ref.read(agentProvider.notifier);
    final wasPaused = logic.uiPaused;
    logic.resumeUiPauseIfNearBottom();
    if (wasPaused && !logic.uiPaused && mounted) {
      setState(() {}); // 恢复态：重建 AgentChatListView 渲染积攒内容
    }
    // "回到底部"按钮显隐（**滞后阈值**，防抖动/防"出现即消失"）：
    // - 未显示时：偏移超过 [kReattachTolerance] 才显示（确实上翻离开底部）；
    // - 已显示时：偏移回落到 [kScrollDragSlop] 附近（几乎贴底）才隐藏；
    // - 中间区间（8~48px）保持当前状态——用户上翻后轻轻回一点不会立刻消失。
    if (!_showScrollToBottom) {
      if (position.pixels > kReattachTolerance && mounted) {
        setState(() => _showScrollToBottom = true);
      }
    } else {
      if (position.pixels <= kScrollDragSlop && mounted) {
        setState(() => _showScrollToBottom = false);
      }
    }
  }

  @override
  void dispose() {
    // 独立路由退出：复位 AI 页可见性（首页 tab 场景由 HomeNotifier 管理）
    if (!widget.isTabEmbedded) {
      HomeTabVisibility.instance.setAgentRoute(false);
    }
    _inputFocusNode.dispose();
    _scroll.removeListener(_onScrollChanged);
    super.dispose();
  }

  /// 触发加载更早历史（自绘列表顶部触发；loadMoreHistory 会更新
  /// service.messages → 自绘列表签名 diff 自动增量插入）
  void _triggerLoadMore() {
    if (_notifier.agentUnavailable) return;
    final svc = _notifier.service!;
    debugPrint(
        'AgentView triggerLoadMore: hasMore=${svc.hasMoreHistory} paginating=$_isPaginating loaded=${svc.loadedHistoryCount}');
    if (!svc.hasMoreHistory) return;
    if (_isPaginating) return;
    _isPaginating = true;
    // 标记分页：logic 的 messages listener 跳过自动滚动，避免跳回底部
    svc.isPaginatingHistory = true;

    try {
      final older = svc.loadMoreHistory();
      if (older.isEmpty) {
        return;
      }
      debugPrint(
          'AgentView loaded older: ${older.length} 条（自绘列表自动增量插入）');
    } catch (e) {
      appLog.error('AgentView: 加载更早历史失败 - $e');
    } finally {
      _isPaginating = false;
      // 延迟重置：等消息通知（异步）派发完成后，避免滚动监听误触发
      WidgetsBinding.instance.addPostFrameCallback((_) {
        svc.isPaginatingHistory = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // AutomaticKeepAliveClientMixin 要求
    // 按字段拆分监听（而不是整体 watch agentProvider）：
    // 流式输出时 messageCount 每个 chunk 都变化，整体 watch 会导致整页（含
    // 消息列表外层 Stack/AnimatedPadding）每 chunk 重建一次 → 视觉跳动。
    // messageCount 由自绘列表内部消费（空态欢迎页），页面本身不监听它。
    final isInitialized =
        ref.watch(agentProvider.select((s) => s.isInitialized));
    final isGenerating =
        ref.watch(agentProvider.select((s) => s.isGenerating));
    final errorMessage =
        ref.watch(agentProvider.select((s) => s.errorMessage));
    final logic = ref.read(agentProvider.notifier);
    return Scaffold(
      // 手动键盘布局：禁用内嵌 Scaffold 自动压缩（否则 body 内 viewInsets 被
      // 消费为 0，悬浮输入栏的 viewInsets 顶起逻辑失效，输入栏停在半空）
      resizeToAvoidBottomInset: false,
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('AI 助手'),
            if (isInitialized)
              Text(
                logic.currentModelName,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: '新建会话',
            icon: const Icon(Icons.add_comment_outlined),
            onPressed: logic.newSession,
          ),
          IconButton(
            tooltip: '会话列表',
            icon: const Icon(Icons.history),
            onPressed: () => _showSessionList(context, logic),
          ),
          IconButton(
            tooltip: '模型设置',
            icon: const Icon(Icons.settings_outlined),
            onPressed: logic.openSettings,
          ),
        ],
      ),
      // 悬浮输入栏：消息列表在下（readOnly 隐藏库内置输入栏），
      // 磨砂输入栏覆盖在消息之上（与底部导航胶囊同款磨砂风格）
      // 键盘处理（resizeToAvoidBottomInset: false 手动模式）：
      // - 消息区 AnimatedPadding 让出键盘高度（底部 = 键盘顶）
      // - 输入栏 AnimatedPadding 顶起（紧贴键盘上方，平滑过渡）
      body: Stack(
        children: [
          Positioned.fill(
            child: AnimatedPadding(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(context).viewInsets.bottom,
              ),
              child: Column(
                children: [
                  // 未配置提示
                  _buildConfigBanner(context, isInitialized, logic),

                  // AI 聊天界面（自绘消息列表，空消息时显示欢迎页）
                  // 外层 Listener 只做手势采集、不消费事件：判断用户是"主动上翻
                  // 阅读"还是"只是点了一下"，供流式输出决定要不要自动滚底。
                  // 手势起落同步 setState：把 logic.uiPaused（挂起标志）变化
                  // 传给 AgentChatListView（冻结/恢复消息列表更新）。
                  Expanded(
                    child: Listener(
                      onPointerDown: (_) {
                        logic.onPointerDown();
                        setState(() {});
                      },
                      onPointerMove: (event) =>
                          logic.onPointerMove(event.delta),
                      onPointerUp: (_) {
                        logic.onPointerUp();
                        setState(() {});
                      },
                      onPointerCancel: (_) {
                        logic.onPointerUp();
                        setState(() {});
                      },
                      child: _buildChatArea(context, isGenerating,
                          errorMessage, logic.uiPaused, logic),
                    ),
                  ),
                ],
              ),
            ),
          ),
          // 悬浮磨砂输入栏：AnimatedPadding 按键盘高度平滑顶起
          // （tab 内嵌且 AI 激活时胶囊滑出 → 贴底 16 + 左侧"返回"按钮；
          //   非激活时胶囊在场 → 上浮 100；独立页面常规贴底 16；
          //   键盘弹出时均紧贴键盘上方）
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _buildFloatingInputWrapper(context),
          ),
          // "回到底部"悬浮按钮：用户上翻阅读/偏离底部时出现（右侧、输入栏上方），
          // 点击无条件回到最新消息（解除挂起 + 贴底 + 展示积攒内容）
          if (_showScrollToBottom)
            Positioned(
              right: AppSpacing.md,
              // 在输入栏上方避让：
              // - 键盘弹出时：按钮需在键盘高度之上（Stack 相对 body，底部含
              //   键盘区域），再叠加输入栏占位 _inputBarClearance + 间距；
              // - 无键盘：_inputBarClearance 即输入栏占位（含呼吸），再加间距。
              bottom: MediaQuery.of(context).viewInsets.bottom > 0
                  ? MediaQuery.of(context).viewInsets.bottom +
                      _inputBarClearance() +
                      AppSpacing.lg
                  : _inputBarClearance() + AppSpacing.lg,
              child: _buildScrollToBottomButton(context),
            ),
        ],
      ),
    );
  }

  /// "回到底部"按钮：悬浮圆钮（带"回到最新"角标 + 键盘避让）
  Widget _buildScrollToBottomButton(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHighest,
      shape: const CircleBorder(),
      elevation: 3,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: () {
          _notifier.jumpToLatest();
          setState(() => _showScrollToBottom = false);
        },
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Icon(
            Icons.arrow_downward,
            size: AppTypography.iconMD,
            color: scheme.primary,
          ),
        ),
      ),
    );
  }

  /// 悬浮输入栏外层：按键盘高度与 AI tab 激活状态计算贴底/上浮
  Widget _buildFloatingInputWrapper(BuildContext context) {
    final homeIndex = ref.watch(homeProvider.select((s) => s.index));
    final aiActive = widget.isTabEmbedded && homeIndex == 2;
    return AnimatedPadding(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom > 0
            ? MediaQuery.of(context).viewInsets.bottom + AppSpacing.md
            : widget.isTabEmbedded
                ? (aiActive ? 16 : 100)
                : 16,
      ),
      child: _buildFloatingInput(context, showBack: aiActive),
    );
  }

  /// 顶部提示条：模块未启用 →「去启用」；未配置模型 →「去设置」
  Widget _buildConfigBanner(
    BuildContext context,
    bool isInitialized,
    AgentNotifier logic,
  ) {
    if (logic.agentUnavailable) {
      // Agent 模块未启用：降级提示（不渲染聊天区）
      return Container(
        width: double.infinity,
        margin: AppSpacing.onlyHorizontalMD,
        padding: AppSpacing.allMD,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: AppRadius.allMD,
        ),
        child: Row(
          children: [
            const Icon(Icons.info_outline, color: AppColors.warning),
            const SizedBox(width: AppSpacing.md),
            const Expanded(
              child: Text('Agent 模块未启用，对话不可用'),
            ),
            TextButton(
              onPressed: () => context.push(AppRoute.moduleManage),
              child: const Text('去启用'),
            ),
          ],
        ),
      );
    }
    if (isInitialized) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      margin: AppSpacing.onlyHorizontalMD,
      padding: AppSpacing.allMD,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primaryContainer,
        borderRadius: AppRadius.allMD,
      ),
      child: Row(
        children: [
          const Icon(Icons.warning_amber_rounded, color: AppColors.warning),
          const SizedBox(width: AppSpacing.md),
          const Expanded(
            child: Text('请先配置 LLM 模型（API Key）'),
          ),
          TextButton(
            onPressed: logic.openSettings,
            child: const Text('去设置'),
          ),
        ],
      ),
    );
  }

  /// 聊天区：模块未启用占位 / 自绘消息列表 + 工具调用系统
  Widget _buildChatArea(
    BuildContext context,
    bool isGenerating,
    String errorMessage,
    bool uiPaused,
    AgentNotifier logic,
  ) {
    final errMsg = errorMessage;
    if (logic.agentUnavailable) {
      // Agent 模块未启用：占位提示（不渲染聊天组件）
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.smart_toy_outlined,
              size: AppTypography.iconXXXL,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: AppSpacing.md),
            Text(
              errMsg.isEmpty ? 'Agent 模块未启用' : errMsg,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ],
        ),
      );
    }
    final svc = logic.service!;
    // 原生工具调用系统：注册 Agent 工具到 AiActionProvider
    return AiActionProvider(
      config: AiActionConfig(
        actions: svc.buildActions(),
      ),
      controller: svc.actionController,
      // 自绘消息列表（item 缓存 + 签名 diff，流式更新零全量重建）
      child: AgentChatListView(
        messages: svc.messages,
        scrollController: logic.scrollController,
        isGenerating: isGenerating,
        hasMoreHistory: svc.hasMoreHistory,
        // 用户交互期间挂起流式 UI（读历史零打扰），
        // 由 logic 手势状态机驱动（onPointerUp 三路判定）
        uiPaused: uiPaused,
        onLoadMore: _triggerLoadMore,
        onSendExample: (text) {
          if (logic.agentUnavailable) {
            AppDialogs.showError('Agent 模块未启用');
            return;
          }
          logic.sendText(text);
        },
        bottomPadding: _inputBarClearance(),
      ),
    );
  }

  /// 输入栏避让高度（键盘/胶囊状态下的悬浮输入栏占位，消息列表与
  /// "回到底部"按钮共用同一套数值保证视觉一致不重叠）
  double _inputBarClearance() {
    return MediaQuery.of(context).viewInsets.bottom > 0
        ? 72
        : widget.isTabEmbedded
            ? (ref.read(homeProvider).index == 2 ? 80 : 156)
            : 80;
  }

  /// 悬浮磨砂输入栏：与底部导航胶囊同款磨砂（BackdropFilter + 半透明主题底）
  /// 悬浮磨砂输入栏：与底部导航胶囊同款磨砂（BackdropFilter + 半透明主题底）
  /// [showBack] 为 true（AI tab 激活、胶囊滑出）时，左侧显示"返回来源 tab"按钮
  Widget _buildFloatingInput(BuildContext context, {bool showBack = false}) {
    final scheme = Theme.of(context).colorScheme;
    final logic = ref.read(agentProvider.notifier);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadius.xxl + AppRadius.sm),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.xs,
              vertical: AppSpacing.xs,
            ),
            decoration: BoxDecoration(
              // 半透明磨砂底（alpha 0.65：更透，背后消息滚动可见）
              color: scheme.surface.withValues(alpha: 0.65),
              borderRadius: BorderRadius.circular(AppRadius.xxl + AppRadius.sm),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // 返回来源 tab 按钮（与发送按钮对称；仅胶囊滑出时显示）
                if (showBack) ...[
                  _buildBackButton(context),
                  const SizedBox(width: AppSpacing.xs),
                ],
                Expanded(
                  child: TextField(
                    controller: logic.inputController,
                    focusNode: _inputFocusNode,
                    style: Theme.of(context).textTheme.bodyMedium,
                    // 多行自动换行：1 行起，最高 4 行（超出内部滚动）
                    minLines: 1,
                    maxLines: 4,
                    keyboardType: TextInputType.multiline,
                    textInputAction: TextInputAction.newline,
                    decoration: InputDecoration(
                      hintText: '输入你的需求...',
                      hintStyle: TextStyle(color: scheme.onSurfaceVariant),
                      // 无内框/无填充：显式覆盖全局主题的 OutlineInputBorder，
                      // 输入区直接透出磨砂容器底色，与胶囊融为一体
                      filled: false,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      disabledBorder: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.lg,
                        vertical: AppSpacing.md,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.xs),
                _buildSendButton(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 发送按钮（生成中禁用 + loading）
  Widget _buildSendButton() {
    final sending = ref.watch(agentProvider.select((s) => s.isGenerating));
    return IconButton.filled(
      onPressed: sending ? null : _submitInput,
      icon: sending
          ? const AppLoading(size: AppLoadingSize.small)
          : const Icon(Icons.send),
      tooltip: '发送',
    );
  }

  /// 悬浮输入栏发送：与库内置输入栏等价（清空输入框后调用 sendText）
  void _submitInput() {
    final notifier = ref.read(agentProvider.notifier);
    final text = notifier.inputController.text.trim();
    if (text.isEmpty) return;
    if (notifier.agentUnavailable) {
      // Agent 模块未启用：弹提示不发送
      AppDialogs.showError('Agent 模块未启用');
      return;
    }
    notifier.inputController.clear();
    notifier.sendText(text);
  }

  /// 返回来源 tab 按钮（图标 = 进入 AI 页前的 tab，点击直接跳回并展开导航）
  /// filledTonal 圆底装饰，与右侧发送按钮（filled）视觉对称
  Widget _buildBackButton(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final homeState = ref.read(homeProvider);
    final sourceIndex = homeState.sourceIndex;
    final (icon, tooltip) = switch (sourceIndex) {
      0 => (
          ColoredAliIcon(
            icon: AliIcon.appStore,
            size: AppTypography.iconMD,
            color: scheme.onSecondaryContainer,
          ),
          '返回首页',
        ),
      1 => (
          Icon(
            Icons.explore_outlined,
            size: AppTypography.iconMD,
            color: scheme.onSecondaryContainer,
          ),
          '返回发现',
        ),
      3 => (
          Icon(
            Icons.person_outline,
            size: AppTypography.iconMD,
            color: scheme.onSecondaryContainer,
          ),
          '返回我的',
        ),
      _ => (
          Icon(
            Icons.apps,
            size: AppTypography.iconMD,
            color: scheme.onSecondaryContainer,
          ),
          '返回',
        ),
    };
    return IconButton.filledTonal(
      tooltip: tooltip,
      icon: icon,
      onPressed: () =>
          ref.read(homeProvider.notifier).jumpToPage(sourceIndex),
    );
  }

  /// 显示会话列表弹窗（切换/删除）
  Future<void> _showSessionList(BuildContext context, AgentNotifier logic) async {
    if (logic.agentUnavailable) return;
    // 确保 Agent 已初始化（会话存储已加载）
    await logic.ensureInitialized();

    final svc = logic.service;
    if (svc == null) return;

    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (context) {
        // 消息变化时刷新列表（会话增删/切换）
        return ValueListenableBuilder<List<AgentMessage>>(
          valueListenable: svc.messages,
          builder: (context, _, __) {
            final service = logic.service;
            if (service == null) {
              return const SizedBox.shrink();
            }
            final currentId = service.currentSessionId;
            final sessions = service.sessions;
            return Padding(
              padding: AppSpacing.allMD,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Text(
                        '会话列表',
                        style: Theme.of(context)
                            .textTheme
                            .titleMedium
                            ?.copyWith(
                              fontWeight: AppTypography.weightSemiBold,
                            ),
                      ),
                      const Spacer(),
                      TextButton.icon(
                        onPressed: () {
                          Navigator.pop(context);
                          logic.newSession();
                        },
                        icon: const Icon(Icons.add, size: 18),
                        label: const Text('新建'),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  if (sessions.isEmpty)
                    Padding(
                      padding: AppSpacing.allXL,
                      child: Text(
                        '暂无会话，点击"新建"开始对话',
                        style: Theme.of(context)
                            .textTheme
                            .bodyMedium
                            ?.copyWith(
                              color: AppColors.textSecondary,
                            ),
                      ),
                    )
                  else
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: MediaQuery.of(context).size.height * 0.5,
                      ),
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: sessions.length,
                        itemBuilder: (context, index) {
                          final session = sessions[index];
                          final isCurrent = session.id == currentId;
                          return ListTile(
                            dense: true,
                            leading: Icon(
                              isCurrent
                                  ? Icons.forum
                                  : Icons.chat_bubble_outline,
                              size: AppTypography.iconMD,
                              color: isCurrent
                                  ? Theme.of(context).colorScheme.primary
                                  : AppColors.textSecondary,
                            ),
                            title: Text(
                              session.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context)
                                  .textTheme
                                  .bodyMedium
                                  ?.copyWith(
                                    fontWeight: isCurrent
                                        ? AppTypography.weightSemiBold
                                        : FontWeight.w400,
                                  ),
                            ),
                            subtitle: Text(
                              _formatSessionTime(session.updatedAt),
                              style: Theme.of(context)
                                  .textTheme
                                  .labelSmall
                                  ?.copyWith(
                                    color: AppColors.textTertiary,
                                  ),
                            ),
                            trailing: IconButton(
                              icon: const Icon(Icons.delete_outline,
                                  size: 18),
                              onPressed: () async {
                                Navigator.pop(context);
                                await logic.deleteSession(session.id);
                              },
                            ),
                            onTap: () {
                              Navigator.pop(context);
                              logic.switchSession(session.id);
                            },
                          );
                        },
                      ),
                    ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  /// 格式化会话时间
  String _formatSessionTime(int millis) {
    final time = DateTime.fromMillisecondsSinceEpoch(millis);
    final now = DateTime.now();
    final diff = now.difference(time);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inHours < 1) return '${diff.inMinutes} 分钟前';
    if (diff.inDays < 1) return '${diff.inHours} 小时前';
    if (diff.inDays < 7) return '${diff.inDays} 天前';
    return '${time.month}/${time.day}';
  }
}