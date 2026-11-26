import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:flutter_gen_ai_chat_ui/flutter_gen_ai_chat_ui.dart'
    hide AgentState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:gstore/page/home/logic.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/design/app_borders.dart';

import 'logic.dart';
import 'chat_list_view.dart';
import 'keyboard_inset_layout.dart';
import 'agent_more_action.dart';
import 'slash_commands.dart';
import 'slash_command_palette.dart';
import 'workspace_picker.dart';

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
    with AutomaticKeepAliveClientMixin, SingleTickerProviderStateMixin {
  @override
  bool get wantKeepAlive => true;

  /// 键盘避让动画时长/曲线（消息区、输入栏、列表内边距共用同一套值）
  static const Duration _keyboardDuration = Duration(milliseconds: 200);
  static const Curve _keyboardCurve = Curves.easeOut;

  /// 键盘高度动画：唯一驱动源。
  ///
  /// 原来消息区/输入栏各用一个 AnimatedPadding，而列表 bottomPadding 在
  /// `keyboard > 0` 分支上瞬时切换，键盘收起最后一帧会多出安全区高度导致
  /// 内容抖动。这里改为一个控制器同时驱动三者，保证几何连续。
  late final AnimationController _insetController;
  Tween<double> _insetTween = Tween<double>(begin: 0, end: 0);
  double _insetTarget = 0;

  /// 当前动画中的键盘高度（逻辑像素）
  double get _keyboardInset => _insetTween.transform(
        _keyboardCurve.transform(_insetController.value),
      );

  /// 悬浮输入框焦点（tab 内嵌时离开 AI tab 自动失焦收键盘）
  final FocusNode _inputFocusNode = FocusNode();

  /// 滚动控制器（AgentNotifier 持有；initState 取引用，dispose 时 ref 不可用）
  late final ScrollController _scroll;

  /// 是否正在分页加载（分页时跳过自动滚动，避免跳回底部）
  bool _isPaginating = false;

  /// 是否显示"回到底部"按钮（用户上翻阅读/偏离底部时出现，回底后隐藏）
  bool _showScrollToBottom = false;

  /// 输入框是否以 '/' 开头（显示快捷指令面板）
  bool _slashActive = false;

  /// 输入胶囊内发送/返回按钮的边长（输入行垂直居中依赖它）
  static const double _inputButtonSize = 40;

  /// 输入控制器引用（dispose 时 ref 已不可用，不能经 _notifier 取）
  TextEditingController? _inputController;


  AgentNotifier get _notifier => ref.read(agentProvider.notifier);

  @override
  void initState() {
    super.initState();
    _insetController = AnimationController(
      vsync: this,
      duration: _keyboardDuration,
    );
    // 独立路由进入：标记 AI 页可见（服务层后台通知/敏感拦截门控）
    if (!widget.isTabEmbedded) {
      HomeTabVisibility.instance.setAgentRoute(true);
    }
    // 触发 AgentNotifier 建立（首帧初始化）
    ref.read(agentProvider);
    _inputController = _notifier.inputController;
    _inputController!.addListener(_onInputChanged);

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

  /// MediaQuery 键盘高度变化：从当前动画位置平滑追到新目标。
  ///
  /// 不用 `AnimatedPadding` 的内部隐式动画：键盘收起时 Android 往往在最后
  /// 才把 inset 置 0，隐式动画会滞后 200ms；这里与其他避让值共用同一个
  /// 动画进度，避免“键盘没了页面还在动”。
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final target = MediaQuery.viewInsetsOf(context).bottom;
    if (target == _insetTarget) return;
    final current = _keyboardInset;
    _insetTween = Tween<double>(begin: current, end: target);
    _insetTarget = target;
    _insetController.forward(from: 0);
  }

  /// 输入变化：以 '/' 开头时显示快捷指令面板。
  void _onInputChanged() {
    if (!mounted) return;
    final active = (_inputController?.text ?? '').startsWith('/');
    if (active != _slashActive || active) {
      setState(() => _slashActive = active);
    }
  }

  Widget _buildSlashPalette(BuildContext context) {
    final text = _inputController?.text ?? '';
    final query = text.startsWith('/') ? text.substring(1) : '';
    final commands = filterSlashCommands(query);
    final media = MediaQuery.of(context);
    final available =
        (media.size.height - media.viewInsets.bottom).clamp(240.0, 2000.0);
    final maxHeight = (available * 0.35).clamp(140.0, 300.0).toDouble();
    return AgentSlashCommandPalette(
      commands: commands,
      maxHeight: maxHeight,
      onSelected: _runSlashCommand,
    );
  }

  Future<void> _runSlashCommand(AgentSlashCommand command) async {
    final logic = _notifier;
    final service = logic.service;
    logic.inputController.clear();
    _inputFocusNode.unfocus();
    if (!mounted) return;

    switch (command.id) {
      case 'workspace':
        if (service == null) {
          AppDialogs.showError('Agent 模块未启用');
          return;
        }
        await _pickWorkspace(context, service);
      case 'files':
        if (!mounted) return;
        await context.push(AppRoute.agentWorkspace);
      case 'photo':
        await AppDialogs.showAlertSheet(
          title: '照片选择',
          message: '功能预留：后续将支持从相册选择图片并发送给 AI。',
        );
      case 'compact':
        if (service == null) {
          AppDialogs.showError('Agent 模块未启用');
          return;
        }
        final compacted = await service.compactSessionNow();
        AppDialogs.showSuccess(compacted ? '已压缩上下文' : '当前会话无需压缩');
      case 'new':
        await logic.newSession();
      case 'model':
        await logic.openSettings();
      case 'clear':
        final ok = await AppDialogs.showConfirmSheet(
          title: '清空当前对话',
          message: '将删除当前会话的消息记录，且不可恢复。',
          isDangerous: true,
          confirmText: '清空',
        );
        if (ok == true && mounted) {
          await logic.clearCurrentSession();
        }
      case 'help':
        if (!mounted) return;
        await _showSlashHelp();
    }
  }

  Future<void> _pickWorkspace(
    BuildContext context,
    AgentService service,
  ) async {
    final info = await showAgentWorkspacePicker(context, service);
    if (info == null || !mounted) return;
    try {
      final ok = await service.setWorkspaceForCurrentSession(info.id);
      if (!ok) {
        AppDialogs.showError('生成中不能切换工作区');
      } else {
        AppDialogs.showSuccess('已切换到 ${info.name}');
      }
    } catch (error) {
      AppDialogs.showError('切换工作区失败：$error');
    }
  }

  /// 输入胶囊内部、输入框下方的工作区胶囊。
  ///
  /// 单行时浮在「输入框底部 - 胶囊底部」的空隙中间，不改变胶囊默认 64dp
  /// 高度；多行时由调用方在底部留出空间，避免与文字重叠。
  Widget _buildWorkspaceInlineLabel(
    BuildContext context,
    AgentNotifier logic, {
    required bool showBack,
  }) {
    final service = logic.service;
    if (service == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    // 与输入框文字左对齐（胶囊内边距 + 返回按钮 + 输入框内边距）
    final left = AppSpacing.lg +
        (showBack ? _inputButtonSize + AppSpacing.xs : 0);
    return Positioned(
      left: left,
      bottom: 5,
      child: ValueListenableBuilder<AgentWorkspaceInfo?>(
        valueListenable: service.currentWorkspace,
        builder: (context, info, _) {
          final name = info?.name ?? '默认工作区';
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _pickWorkspace(context, service),
            child: Container(
              key: const Key('agent-workspace-pill'),
              constraints: BoxConstraints(
                maxWidth: MediaQuery.sizeOf(context).width * 0.55,
              ),
              // 极小的上下内边距，胶囊更贴合文字
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.sm,
                vertical: 1,
              ),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest.withValues(alpha: 0.7),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(
                  color: scheme.outlineVariant.withValues(alpha: 0.35),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    TablerIcons.folder,
                    size: AppTypography.iconXXS,
                    color: scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 3),
                  Flexible(
                    child: Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                            height: 1.0,
                          ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// 估算输入文本是否会换行成多行：多行时给工作区胶囊让出底部空间，
  /// 避免文字与胶囊重叠。按输入框实际可用宽度用 TextPainter 预排。
  bool _inputWrapsToMultipleLines(
    BuildContext context,
    String text,
    double contentWidth, {
    required bool showBack,
  }) {
    if (text.isEmpty) return false;
    final style = Theme.of(context).textTheme.bodyMedium;
    final textWidth = contentWidth -
        (showBack ? _inputButtonSize + AppSpacing.xs : 0) -
        AppSpacing.xs -
        _inputButtonSize -
        AppSpacing.lg * 2 -
        8; // 预留光标与取整误差，宁可提前判定换行
    if (textWidth <= 0) return true;
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 4,
    )..layout(maxWidth: textWidth);
    return painter.computeLineMetrics().length > 1;
  }

  Future<void> _showSlashHelp() {
    return AppSheet.show<void>(
      context: context,
      title: '快捷指令',
      subtitle: '在输入框输入 / 即可打开',
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final command in kAgentSlashCommands)
            ListTile(
              dense: true,
              leading: Icon(command.icon, size: AppTypography.iconMD),
              title: Row(
                children: [
                  Text(
                    command.command,
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Text(
                      command.title,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant,
                          ),
                    ),
                  ),
                ],
              ),
              subtitle: Text(command.subtitle),
            ),
        ],
      ),
    );
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
    _inputController?.removeListener(_onInputChanged);
    _inputFocusNode.dispose();
    _insetController.dispose();
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
    // 消息列表外层 Stack/键盘动画）每 chunk 重建一次 → 视觉跳动。
    // messageCount 由自绘列表内部消费（空态欢迎页），页面本身不监听它。
    final isInitialized =
        ref.watch(agentProvider.select((s) => s.isInitialized));
    final isGenerating =
        ref.watch(agentProvider.select((s) => s.isGenerating));
    final errorMessage =
        ref.watch(agentProvider.select((s) => s.errorMessage));
    final logic = ref.read(agentProvider.notifier);
    // AI tab 激活时导航胶囊滑出，输入胶囊落到胶囊原位（同时显示返回按钮）
    final aiActive = widget.isTabEmbedded &&
        ref.watch(homeProvider.select((s) => s.index)) == 2;
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
          AgentMoreAction(
            service: logic.service,
            onNewSession: logic.newSession,
            onShowSessions: () => _showSessionList(context, logic),
            onOpenSettings: logic.openSettings,
          ),
        ],
      ),
      // 悬浮输入栏：消息列表在下（readOnly 隐藏库内置输入栏），
      // 磨砂输入栏覆盖在消息之上（与底部导航胶囊同款磨砂风格）
      // 键盘处理（resizeToAvoidBottomInset: false 手动模式）：
      // 消息区、输入栏、列表内边距、回底按钮全部由同一个动画键盘高度
      // (_keyboardInset) 计算，避免键盘收起最后安全区跳变导致的抖动。
      body: AnimatedBuilder(
        animation: _insetController,
        builder: (context, _) {
          final keyboard = _keyboardInset;
          final layout = AgentKeyboardLayout.of(
            keyboard: keyboard,
            inputBarInset:
                _inputBarBottomInset(context, aiActive: aiActive),
          );
          return Stack(
            children: [
              Positioned.fill(
                child: Padding(
                  padding: EdgeInsets.only(bottom: layout.message),
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
                          child: _buildChatArea(
                            context,
                            isGenerating,
                            errorMessage,
                            logic.uiPaused,
                            logic,
                            bottomPadding: layout.list,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              // 悬浮磨砂输入栏
              // （tab 内嵌且 AI 激活时导航胶囊滑出 → 输入胶囊落在胶囊原位
              //   （AppBottomCapsule 等高 + 同外边距）+ 左侧"返回"按钮；
              //   非激活时胶囊在场 → 上浮到导航胶囊上方；独立页面常规贴底；
              //   键盘弹出时均紧贴键盘上方）
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Padding(
                  padding: EdgeInsets.only(bottom: layout.input),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_slashActive) _buildSlashPalette(context),
                      _buildFloatingInput(
                        context,
                        showBack: aiActive,
                        isGenerating: isGenerating,
                      ),
                    ],
                  ),
                ),
              ),
              // "回到底部"悬浮按钮：用户上翻阅读/偏离底部时出现（右侧、输入栏
              // 上方），点击无条件回到最新消息（解除挂起 + 贴底 + 展示积攒内容）
              if (_showScrollToBottom)
                Positioned(
                  right: AppSpacing.md,
                  // 输入胶囊底边 + 胶囊高度 + 呼吸间距 + 与按钮的间距
                  bottom: layout.button,
                  child: _buildScrollToBottomButton(context),
                ),
            ],
          );
        },
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
            TablerIcons.arrow_down,
            size: AppTypography.iconMD,
            color: scheme.primary,
          ),
        ),
      ),
    );
  }

  /// 输入胶囊的底部偏移（不含键盘）：与首页导航胶囊共用同一套外边距与安全区。
  ///
  /// - AI tab 激活（导航胶囊滑出）：输入胶囊正好落在导航胶囊原来的位置；
  /// - 非激活（导航胶囊在场）：输入胶囊浮在导航胶囊上方，留一段呼吸间距；
  /// - 独立路由页：没有导航胶囊，直接贴底。
  double _inputBarBottomInset(BuildContext context, {required bool aiActive}) {
    final safeBottom = _systemBottomInset(context);
    if (!widget.isTabEmbedded || aiActive) {
      return safeBottom + AppBottomCapsule.bottomMargin;
    }
    return safeBottom +
        AppBottomCapsule.bottomMargin +
        AppBottomCapsule.height +
        AppSpacing.xxl;
  }

  /// 系统底部安全区（逻辑像素）。
  ///
  /// 不能用 `MediaQuery` 的 padding/viewPadding：首页 Scaffold 开了 extendBody
  /// 且带 bottomNavigationBar，body 拿到的 MediaQuery 会把底部 padding 换成
  /// 导航胶囊总高度，并顺手从 viewPadding 里扣掉这段（MediaQueryData
  /// .removePadding 的行为），两个值都不是系统安全区。直接读视图原始
  /// viewPadding 才与导航胶囊 SafeArea 用的是同一个值。
  double _systemBottomInset(BuildContext context) {
    final view = View.of(context);
    return MediaQueryData.fromView(view).viewPadding.bottom;
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
            const Icon(TablerIcons.info_circle, color: AppColors.warning),
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
          const Icon(TablerIcons.alert_triangle, color: AppColors.warning),
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
    AgentNotifier logic, {
    required double bottomPadding,
  }) {
    final errMsg = errorMessage;
    if (logic.agentUnavailable) {
      // Agent 模块未启用：占位提示（不渲染聊天组件）
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              TablerIcons.robot,
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
        bottomPadding: bottomPadding,
      ),
    );
  }

  /// 悬浮磨砂输入栏：与底部导航胶囊同款磨砂（BackdropFilter + 半透明主题底）
  /// [showBack] 为 true（AI tab 激活、胶囊滑出）时，左侧显示"返回来源 tab"按钮
  Widget _buildFloatingInput(
    BuildContext context, {
    bool showBack = false,
    required bool isGenerating,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final logic = ref.read(agentProvider.notifier);
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppBottomCapsule.horizontalMargin,
      ),
      // 外描边与首页导航胶囊同款（必须在 ClipRRect 外层，内层会被磨砂/圆角
      // 裁掉），这样两个胶囊切换时边框也能对上。
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppBottomCapsule.radius),
          border: AppBorders.all(
            context,
            color: scheme.outlineVariant.withValues(alpha: 0.6),
          ),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(AppBottomCapsule.radius),
          child: BackdropFilter(
            filter: ImageFilter.blur(
              sigmaX: AppShadows.backdropBlurSigma,
              sigmaY: AppShadows.backdropBlurSigma,
            ),
            child: Container(
              key: const Key('agent-input-capsule'),
              // 与首页导航胶囊等高（单行时 64）：切入 AI tab 时两者位置/高度
              // 完全一致，切换看起来像同一个胶囊在变形；多行输入时随内容增高。
              constraints: const BoxConstraints(
                minHeight: AppBottomCapsule.height,
              ),
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
              decoration: BoxDecoration(
                // 半透明磨砂底（alpha 0.65：更透，背后消息滚动可见）
                color: scheme.surface.withValues(alpha: 0.65),
                borderRadius: BorderRadius.circular(AppBottomCapsule.radius),
              ),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  // 文本变化只重建输入胶囊，不触发整页重建
                  return ValueListenableBuilder<TextEditingValue>(
                    valueListenable: logic.inputController,
                    builder: (context, value, _) {
                      final wraps = _inputWrapsToMultipleLines(
                        context,
                        value.text,
                        constraints.maxWidth,
                        showBack: showBack,
                      );
                      // 单行：按钮在胶囊内垂直居中，输入框文字再上移 4dp
                      // （视觉更居中）；多行：文字顶边距固定 18，底部固定留出
                      // 工作区胶囊的高度（26），胶囊随行数增高。
                      return Stack(
                        children: [
                          Padding(
                            padding: wraps
                                ? const EdgeInsets.only(top: 18, bottom: 26)
                                : const EdgeInsets.all(12),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                // 返回来源 tab 按钮（与发送按钮对称；仅胶囊滑出时显示）
                                if (showBack) ...[
                                  _buildBackButton(context),
                                  const SizedBox(width: AppSpacing.xs),
                                ],
                                Expanded(
                                  // 单行时给输入框底部补 8dp，使文字比按钮中线
                                  // 高 4dp（按钮仍居中于胶囊）；多行时不需要
                                  child: Padding(
                                    padding: EdgeInsets.only(
                                      bottom: wraps ? 0 : 8,
                                    ),
                                    child: TextField(
                                      controller: logic.inputController,
                                      focusNode: _inputFocusNode,
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodyMedium,
                                      // 多行自动换行：1 行起，最高 4 行（超出内部滚动）
                                      minLines: 1,
                                      maxLines: 4,
                                      keyboardType: TextInputType.multiline,
                                      textInputAction:
                                          TextInputAction.newline,
                                      decoration: InputDecoration(
                                        isDense: true,
                                        hintText: '输入你的需求...',
                                        hintStyle: TextStyle(
                                          color: scheme.onSurfaceVariant,
                                        ),
                                        // 无内框/无填充：显式覆盖全局主题的
                                        // OutlineInputBorder，输入区直接透出磨砂底色
                                        filled: false,
                                        border: InputBorder.none,
                                        enabledBorder: InputBorder.none,
                                        focusedBorder: InputBorder.none,
                                        disabledBorder: InputBorder.none,
                                        // 不加垂直内边距：文字上下留白由布局均分
                                        contentPadding:
                                            const EdgeInsets.symmetric(
                                          horizontal: AppSpacing.lg,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: AppSpacing.xs),
                                _buildSendButton(isGenerating),
                              ],
                            ),
                          ),
                          // 工作区胶囊：浮在输入框底部与胶囊底部之间的空隙中居中
                          if (logic.service != null)
                            _buildWorkspaceInlineLabel(
                              context,
                              logic,
                              showBack: showBack,
                            ),
                        ],
                      );
                    },
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 发送按钮：空闲时发送，生成中切换为停止按钮（点击中断本轮生成）
  Widget _buildSendButton(bool sending) {
    if (sending) {
      return IconButton.filled(
        key: const Key('agent-stop-button'),
        style: IconButton.styleFrom(
          minimumSize: const Size(_inputButtonSize, _inputButtonSize),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        onPressed: () => ref.read(agentProvider.notifier).stopGenerating(),
        icon: const Icon(TablerIcons.player_stop),
        tooltip: '停止生成',
      );
    }
    return IconButton.filled(
      key: const Key('agent-send-button'),
      style: IconButton.styleFrom(
        minimumSize: const Size(_inputButtonSize, _inputButtonSize),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      onPressed: _submitInput,
      icon: const Icon(TablerIcons.send),
      tooltip: '发送',
    );
  }

  /// 悬浮输入栏发送：与库内置输入栏等价（清空输入框后调用 sendText）
  void _submitInput() {
    final notifier = ref.read(agentProvider.notifier);
    final text = notifier.inputController.text.trim();
    if (text.isEmpty) return;
    if (text.startsWith('/')) {
      final name = text.split(RegExp(r'\s+')).first;
      for (final command in kAgentSlashCommands) {
        if (command.command == name) {
          unawaited(_runSlashCommand(command));
          return;
        }
      }
    }
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
          Icon(
            TablerIcons.home,
            size: AppTypography.iconMD,
            color: scheme.onSecondaryContainer,
          ),
          '返回首页',
        ),
      1 => (
          Icon(
            TablerIcons.compass,
            size: AppTypography.iconMD,
            color: scheme.onSecondaryContainer,
          ),
          '返回发现',
        ),
      2 => (
          Icon(
            TablerIcons.message_chatbot,
            size: AppTypography.iconMD,
            color: scheme.onSecondaryContainer,
          ),
          '返回 AI 助手',
        ),
      3 => (
          Icon(
            TablerIcons.user,
            size: AppTypography.iconMD,
            color: scheme.onSecondaryContainer,
          ),
          '返回我的',
        ),
      _ => (
          Icon(
            TablerIcons.message_chatbot,
            size: AppTypography.iconMD,
            color: scheme.onSecondaryContainer,
          ),
          '返回',
        ),
    };
    return IconButton.filledTonal(
      style: IconButton.styleFrom(
        minimumSize: const Size(_inputButtonSize, _inputButtonSize),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
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
                        icon: const Icon(TablerIcons.plus, size: 18),
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
                        maxHeight: MediaQuery.sizeOf(context).height * 0.5,
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
                                  ? TablerIcons.message_circle_filled
                                  : TablerIcons.message_circle,
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
                              icon: const Icon(TablerIcons.trash,
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