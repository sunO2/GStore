import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_gen_ai_chat_ui/flutter_gen_ai_chat_ui.dart' hide AgentState;
import 'package:get/get.dart';
import 'package:gstore/core/agent/agent_service.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/http/download/DownloadStatus.dart';

import 'logic.dart';
import 'state.dart';
import 'markdown_message.dart';

class AgentPage extends StatefulWidget {
  const AgentPage({super.key});

  @override
  State<AgentPage> createState() => _AgentPageState();
}

/// 保持页面状态（作为首页 tab 时切换不销毁：输入/滚动/对话状态保留）
class _AgentPageState extends State<AgentPage>
    with AutomaticKeepAliveClientMixin {
  late final AgentLogic _logic;
  late final AgentState _state;

  @override
  bool get wantKeepAlive => true;

  /// 聊天控制器（flutter_gen_ai_chat_ui）
  final ChatMessagesController _chatController = ChatMessagesController();

  /// 当前用户（本机用户）与 AI 用户
  late final ChatUser _currentUser;
  late final ChatUser _aiUser;

  /// 已同步的消息 ID → ChatMessage（增量 diff）
  final Map<String, ChatMessage> _syncedMessages = {};

  /// 工具消息签名（id+status），变化时触发全量聚合重建
  String _lastToolSignature = '';

  /// 是否正在分页加载（分页时用增量同步，避免 setMessages 重置滚动）
  bool _isPaginating = false;

  /// 是否已初始化同步
  bool _initialSyncDone = false;

  @override
  void initState() {
    super.initState();
    _logic = Get.put(AgentLogic());
    _state = _logic.state;
    _currentUser = ChatUser(id: 'me', name: '我');
    _aiUser = ChatUser(id: 'ai', name: 'GStore 助手');

    // 监听消息变化，增量同步到聊天控制器
    _logic.service.messages.listen(_onMessagesChanged);

    // 监听滚动：reverse 列表接近顶部（最早消息）时加载更早历史
    // 库内部使用 logic.scrollController（传给 AiChatWidget），此处直接监听
    _logic.scrollController.addListener(_onScrollChanged);

    // 初始化同步（若 service 已加载历史消息）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _onMessagesChanged(_logic.service.messages);
    });
  }

  /// 滚动位置变化：接近 reverse 列表顶部时加载更早历史
  void _onScrollChanged() {
    if (!_logic.scrollController.hasClients) return;
    final position = _logic.scrollController.position;
    // reverse 列表：offset 0 = 底部（最新），maxScrollExtent = 顶部（最早）
    if (position.maxScrollExtent > 0 &&
        position.pixels >= position.maxScrollExtent - 100) {
      debugPrint('AgentView nearTop: pixels=${position.pixels.toStringAsFixed(0)} max=${position.maxScrollExtent.toStringAsFixed(0)}');
      _triggerLoadMore();
    }
  }

  @override
  void dispose() {
    _logic.scrollController.removeListener(_onScrollChanged);
    _chatController.dispose();
    super.dispose();
  }

  /// 消息变化时同步（工具消息聚合为容器，文本消息增量）
  void _onMessagesChanged(List<AgentMessage> messages) {
    if (!mounted) return;

    // 会话切换/清空：全量重建
    if (!_initialSyncDone || messages.isEmpty) {
      _rebuildAll();
      _initialSyncDone = true;
      // 首次加载完成：定位到底部（最新消息），避免停留在顶部
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final sc = _logic.scrollController;
        if (sc.hasClients) {
          sc.jumpTo(0);
        }
      });
      return;
    }

    // 分页加载：跳过（由 _triggerLoadMore 的 controller.loadMore 增量处理，
    // 避免 setMessages 全量重建重置滚动位置）
    if (_isPaginating) {
      return;
    }

    // 工具消息签名变化（新增/状态更新）→ 全量聚合重建
    final toolSig = _toolSignature(messages);
    if (toolSig != _lastToolSignature) {
      _lastToolSignature = toolSig;
      _rebuildAll();
      return;
    }

    // 仅文本变化 → 增量（跳过工具消息，已由聚合容器管理）
    final currentIds = <String>{};
    for (final msg in messages) {
      if (msg.isToolResult) continue;
      final existing = _syncedMessages[msg.id];
      if (existing == null) {
        final cm = _toChatMessage(msg);
        _syncedMessages[msg.id] = cm;
        _chatController.addMessage(cm);
      } else {
        // 文本变化才更新（流式）
        final updated = _toChatMessage(msg);
        if (existing.text != updated.text) {
          _syncedMessages[msg.id] = updated;
          _chatController.updateMessage(updated);
        }
      }
      currentIds.add(msg.id);
    }

    // 删除的消息（会话切换等罕见场景）
    final removed = _syncedMessages.keys
        .where((id) => !currentIds.contains(id))
        .toList();
    if (removed.isNotEmpty) {
      for (final id in removed) {
        _syncedMessages.remove(id);
      }
      _rebuildAll();
    }
  }

  /// 工具消息签名（用于检测工具新增/状态变化）
  String _toolSignature(List<AgentMessage> messages) {
    final buf = StringBuffer();
    for (final msg in messages) {
      if (msg.isToolResult) {
        buf.write('${msg.id}:${msg.toolStatus?.name ?? 'null'};');
      }
    }
    return buf.toString();
  }

  /// 消息显示时间（含 seq 微秒偏移）
  ///
  /// 用户消息与 agent 回复可能在同一毫秒创建（发送后立即创建回复消息），
  /// 库的 reverseOrder setMessages 用不稳定 sort 按 createdAt 排序，
  /// 同毫秒时顺序不确定导致 agent 排到用户前。
  /// 方案：把全局递增的 seq 叠加到微秒位（seq：用户 < agent），
  /// 保证同毫秒内用户消息必然早于其 agent 回复。
  DateTime _displayTime(AgentMessage msg) {
    final micros = (msg.seq & 0x3FFFF).toInt(); // 低 18 位（约 26 万，足够）
    return msg.time.add(Duration(microseconds: micros));
  }

  /// 全量重建消息列表（同回合消息按 turnId 聚合为时间轴）
  void _rebuildAll() {
    final msgs = _logic.service.messages;
    final grouped = _groupTimeline(msgs);
    final list = <ChatMessage>[];
    for (var i = 0; i < grouped.length; i++) {
      final item = grouped[i];
      // 使用消息真实时间（msg.time），库按 createdAt 排序显示最新在底部
      list.add(item.turnMsgs != null
          ? _toTimelineMessage(item.turnMsgs!)
          : _toChatMessage(item.msg!));
    }
    _syncedMessages
      ..clear()
      ..addEntries(list.map((cm) {
        // 从 customProperties.id 恢复消息 id
        final id = cm.customProperties?['id']?.toString() ?? cm.hashCode.toString();
        return MapEntry(id, cm);
      }));
    _chatController.setMessages(list);
  }

  /// 触发加载更早历史（增量 addMessages，不重置滚动位置）
  void _triggerLoadMore() {
    debugPrint('AgentView triggerLoadMore: hasMore=${_logic.service.hasMoreHistory} paginating=$_isPaginating loaded=${_logic.service.loadedHistoryCount}');
    if (!_logic.service.hasMoreHistory) return;
    if (_isPaginating) return;
    _isPaginating = true;
    // 标记分页：logic 的 messages listener 跳过自动滚动，避免跳回底部
    _logic.service.isPaginatingHistory = true;

    try {
      final older = _logic.service.loadMoreHistory();
      if (older.isEmpty) {
        _isPaginating = false;
        return;
      }
      debugPrint('AgentView older: ${older.map((m) => m.isUser ? "U" : (m.isToolResult ? "T" : "A")).join(",")}');
      // 转成 ChatMessage（按 turnId 聚合成时间轴）
      final grouped = _groupTimeline(older);
      debugPrint('AgentView grouped: ${grouped.map((g) => g.msg != null ? (g.msg!.isUser ? "U" : "A") : "G").join(",")}');
      final chatMsgs = <ChatMessage>[];
      for (final item in grouped) {
        chatMsgs.add(item.turnMsgs != null
            ? _toTimelineMessage(item.turnMsgs!)
            : _toChatMessage(item.msg!));
      }
      // controller._messages 布局为 [最新...最旧]（index 0 最新），addMessages append 到末尾。
      // 需把更早消息按 createdAt 降序（最新在前、最早在末尾），append 后最早显示在 reverse 列表顶部。
      final olderSorted = chatMsgs.toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
      _chatController.addMessages(olderSorted);
      // 更新同步记录
      for (final msg in older) {
        if (!msg.isToolResult) {
          _syncedMessages[msg.id] = _toChatMessage(msg);
        }
      }
      _lastToolSignature = _toolSignature(_logic.service.messages);
    } catch (e) {
      appLog.error('AgentView: 加载更早历史失败 - $e');
    } finally {
      _isPaginating = false;
      // 延迟重置：等 RxList 通知（异步）派发完成后，避免 logic 的滚动监听误触发
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _logic.service.isPaginatingHistory = false;
      });
    }
  }

  /// 按 turnId 分组：同回合的 agent 文本 + 工具消息合并为一个时间轴；
  /// 用户消息保持独立。
  /// 返回 [(msg, null)] 独立消息 或 [null, turnMsgs] 时间轴消息组
  List<({AgentMessage? msg, List<AgentMessage>? turnMsgs})> _groupTimeline(
      List<AgentMessage> messages) {
    final result = <({AgentMessage? msg, List<AgentMessage>? turnMsgs})>[];
    // 当前回合收集（用户消息不入时间轴）
    var currentTurnId = '';
    var currentTurn = <AgentMessage>[];

    void flushTurn() {
      if (currentTurn.isNotEmpty) {
        // 按 seq 排序（agent 文本在前，工具在后）
        currentTurn.sort((a, b) => a.seq.compareTo(b.seq));
        result.add((msg: null, turnMsgs: List.of(currentTurn)));
        currentTurn = [];
      }
      currentTurnId = '';
    }

    for (final msg in messages) {
      if (msg.isUser) {
        // 用户消息：先结束当前回合，再独立显示
        flushTurn();
        result.add((msg: msg, turnMsgs: null));
      } else if (msg.isToolResult) {
        // 工具消息：归入当前回合；若 turnId 与当前不同，先结束当前回合
        final turnId = msg.turnId ?? '';
        if (currentTurn.isNotEmpty && turnId != currentTurnId && turnId.isNotEmpty) {
          flushTurn();
        }
        if (currentTurnId.isEmpty) currentTurnId = turnId;
        currentTurn.add(msg);
      } else {
        // agent 文本消息：归入当前回合（若同 turnId）或开启新回合
        final turnId = msg.turnId ?? '';
        if (currentTurn.isNotEmpty && turnId != currentTurnId && turnId.isNotEmpty) {
          flushTurn();
        }
        if (currentTurnId.isEmpty) currentTurnId = turnId;
        currentTurn.add(msg);
      }
    }
    flushTurn();
    return result;
  }

  /// 时间轴组 → ChatMessage（customBuilder 渲染 _TurnTimeline）
  /// 时间取该回合最早 agent 回复时间（无 agent 文本时取最早消息时间）
  ChatMessage _toTimelineMessage(List<AgentMessage> turnMsgs) {
    final firstId = turnMsgs.isNotEmpty ? turnMsgs.first.id : 'timeline';
    // 时间轴整体时间 = 回合最早 agent 回复的显示时间（含 seq 微秒偏移，
    // 保证同毫秒下用户消息在前、agent 回合在后）
    final displayTime = _displayTime(turnMsgs.firstWhere(
      (m) => !m.isToolResult,
      orElse: () => turnMsgs.first,
    ));
    return ChatMessage(
      text: '',
      user: _aiUser,
      createdAt: displayTime,
      customProperties: {'id': 'timeline_$firstId'},
      customBuilder: (context, _) => _TurnTimeline(turnMsgs: turnMsgs),
    );
  }

  /// 将 AgentMessage 转换为 ChatMessage
  ChatMessage _toChatMessage(AgentMessage msg) {
    if (msg.isToolResult) {
      // 工具消息：用自定义 widget 渲染工具气泡
      return ChatMessage(
        text: '',
        user: _aiUser,
        createdAt: _displayTime(msg),
        customProperties: {'id': msg.id},
        customBuilder: (context, _) => _ToolBubble(msg: msg),
      );
    }
    if (msg.isUser) {
      return ChatMessage(
        text: msg.text,
        user: _currentUser,
        createdAt: _displayTime(msg),
        customProperties: {'id': msg.id},
      );
    }
    return ChatMessage(
      text: msg.text,
      user: _aiUser,
      createdAt: _displayTime(msg),
      isMarkdown: true,
      customProperties: {'id': msg.id},
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // AutomaticKeepAliveClientMixin 要求
    final logic = _logic;
    final state = _state;
    return Scaffold(
      appBar: AppBar(
        title: Obx(() {
          final isInit = state.isInitialized.value;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('AI 助手'),
              if (isInit)
                Text(
                  logic.currentModelName,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
            ],
          );
        }),
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
      body: Column(
        children: [
          // 未配置提示
          Obx(() {
            if (state.isInitialized.value) return const SizedBox.shrink();
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
                  const Icon(Icons.warning_amber_rounded,
                      color: AppColors.warning),
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
          }),

          // AI 聊天界面（始终渲染 AiChatWidget，空消息时显示欢迎页）
          Expanded(
            child: Obx(() {
              final messages = logic.service.messages;
              final isEmpty = messages.isEmpty;
              // 原生工具调用系统：注册 Agent 工具到 AiActionProvider
              return AiActionProvider(
                config: AiActionConfig(
                  actions: logic.service.buildActions(),
                ),
                controller: logic.service.actionController,
                child: AiChatWidget(
                  currentUser: _currentUser,
                  aiUser: _aiUser,
                  controller: _chatController,
                  // 共享 scrollController，让库的分页滚动检测与 loadMoreHistoryIfNeeded 使用同一 controller
                  scrollController: logic.scrollController,
                  onSendMessage: (chatMsg) {
                    _handleSendMessage(chatMsg);
                  },
                  // 停止生成（对话流 + 工具调用）
                  onCancelGenerating: () {
                    logic.service.stopGenerating();
                  },
                  welcomeMessageConfig: isEmpty
                      ? WelcomeMessageConfig(
                          title: 'GStore AI 助手',
                          questionsSectionTitle: '可以试试这样问我：',
                        )
                      : null,
                  exampleQuestions: [
                    ExampleQuestion(question: '帮我找一个截图工具'),
                    ExampleQuestion(question: '帮我下载 Termux'),
                    ExampleQuestion(question: '检查我的应用是否有更新'),
                  ],
                  messageOptions: _buildMessageOptions(context),
                  inputOptions: _buildInputOptions(context, logic, state),
                  // 减小消息列表左右间距（默认 16 → 8）
                  spacingConfig: const ChatSpacingConfig(
                    messageListPadding: EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 8,
                    ),
                  ),
                  enableMarkdownStreaming: true,
                  streamingWordByWord: false,
                  loadingConfig: LoadingConfig(
                    isLoading: state.isGenerating.value,
                    loadingIndicator: const AppLoading(size: AppLoadingSize.small),
                  ),
                  messageListOptions: MessageListOptions(
                    onLoadMore: () async {
                      // 官方方案：controller.loadMore 增量加载（addMessages，不重置滚动）
                      _triggerLoadMore();
                    },
                    hasMoreMessages: logic.service.hasMoreHistory,
                    paginationConfig: PaginationConfig(
                      enabled: true,
                      // 库的 reverse 分页触发方向与"向上加载更早"不符，关闭自动加载，
                      // 由 scrollController 监听视觉顶部触发
                      autoLoadOnScroll: false,
                    ),
                  ),
                ),
              );
            }),
          ),
        ],
      ),
    );
  }

  /// 发送消息
  Future<void> _handleSendMessage(ChatMessage chatMsg) async {
    final text = chatMsg.text.trim();
    if (text.isEmpty) return;
    await _logic.sendText(text);
  }

  /// 消息气泡样式（匹配现有风格）
  MessageOptions _buildMessageOptions(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bubbleMaxWidth = MediaQuery.of(context).size.width * 0.93;
    return MessageOptions(
      bubbleStyle: BubbleStyle(
        userBubbleColor: scheme.primaryContainer,
        aiBubbleColor: scheme.surfaceContainerHighest,
        userBubbleTopLeftRadius: AppRadius.md,
        aiBubbleTopRightRadius: AppRadius.md,
        bottomLeftRadius: AppRadius.sm,
        bottomRightRadius: AppRadius.sm,
        aiBubbleMaxWidth: bubbleMaxWidth,
        userBubbleMaxWidth: bubbleMaxWidth,
      ),
      // 气泡与屏幕边缘的间距（默认 16 → 8，更紧凑）
      containerMargin: const EdgeInsets.symmetric(horizontal: 8),
      showTime: true,
      showUserName: false,
      // 时间格式：当天显示时分，跨天显示日期+时间
      timeFormat: (time) {
        final h = time.hour.toString().padLeft(2, '0');
        final m = time.minute.toString().padLeft(2, '0');
        final now = DateTime.now();
        final isToday = time.year == now.year &&
            time.month == now.month &&
            time.day == now.day;
        if (isToday) return '$h:$m';
        return '${time.month}/${time.day} $h:$m';
      },
      userTextColor: scheme.onPrimaryContainer,
      aiTextColor: scheme.onSurface,
      textStyle: Theme.of(context).textTheme.bodyMedium,
      // 定制用户气泡：渐变 + 不对称圆角 + 阴影（agent 消息用默认气泡）
      bubbleBuilder: (context, message, isCurrentUser, defaultBubble) {
        if (!isCurrentUser) return defaultBubble;
        return Align(
          alignment: Alignment.centerRight,
          child: Container(
            constraints: BoxConstraints(
              maxWidth: bubbleMaxWidth,
            ),
            padding: EdgeInsets.symmetric(
              horizontal: 14,
              vertical: 10,
            ),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  scheme.primary,
                  scheme.primary.withValues(alpha: 0.85),
                ],
              ),
              borderRadius: BorderRadius.only(
                topLeft: Radius.circular(AppRadius.lg),
                topRight: Radius.circular(AppRadius.lg),
                bottomLeft: Radius.circular(AppRadius.lg),
                bottomRight: Radius.circular(AppRadius.sm),
              ),
              boxShadow: [
                BoxShadow(
                  color: scheme.primary.withValues(alpha: 0.25),
                  blurRadius: 8,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  message.text,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: scheme.onPrimary,
                        height: 1.4,
                      ),
                ),
                const SizedBox(height: 2),
                Text(
                  _formatMessageTime(message.createdAt),
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: scheme.onPrimary.withValues(alpha: 0.8),
                        fontSize: 10,
                      ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 格式化消息时间（当天时分，跨天日期+时间）
  String _formatMessageTime(DateTime time) {
    final h = time.hour.toString().padLeft(2, '0');
    final m = time.minute.toString().padLeft(2, '0');
    final now = DateTime.now();
    final isToday = time.year == now.year &&
        time.month == now.month &&
        time.day == now.day;
    if (isToday) return '$h:$m';
    return '${time.month}/${time.day} $h:$m';
  }

  /// 输入栏样式（悬浮效果：底部留白 + 圆角 + 阴影）
  InputOptions _buildInputOptions(
    BuildContext context,
    AgentLogic logic,
    AgentState state,
  ) {
    final scheme = Theme.of(context).colorScheme;
    return InputOptions(
      textController: logic.inputController,
      textStyle: Theme.of(context).textTheme.bodyMedium,
      sendOnEnter: true,
      decoration: InputDecoration(
        hintText: '输入你的需求...',
        hintStyle: TextStyle(color: scheme.onSurfaceVariant),
        filled: true,
        fillColor: scheme.surfaceContainerHighest,
        border: OutlineInputBorder(
          // 半圆：大圆角（内部 contentPadding 相应调整，文本不顶边）
          borderRadius: BorderRadius.circular(AppRadius.circle),
          borderSide: BorderSide.none,
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.md,
        ),
      ),
      sendButtonBuilder: (onSend) => Obx(() {
        final sending = state.isGenerating.value;
        return IconButton.filled(
          onPressed: sending ? null : onSend,
          icon: sending
              ? const AppLoading(size: AppLoadingSize.small)
              : const Icon(Icons.send),
          tooltip: '发送',
        );
      }),
      // 悬浮外壳：无背景/无边框（仅阴影体现悬浮），圆角半圆
      useOuterContainer: false,
      // 关键：外层容器默认 padding 16px 会把阴影区域扩大一圈，
      // 设为 0 让阴影紧贴输入组件本体
      padding: EdgeInsets.zero,
      containerPadding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.xs,
        vertical: AppSpacing.xs,
      ),
      margin: EdgeInsets.only(
        left: 2,
        right: 2,
        top: 2,
        bottom: AppSpacing.sm,
      ),
      containerDecoration: BoxDecoration(
        // 圆角与输入框一致（胶囊），阴影紧贴输入组件轮廓而非整块矩形
        borderRadius: BorderRadius.circular(AppRadius.circle),
        boxShadow: [
          BoxShadow(
            color: scheme.shadow.withValues(alpha: 0.08),
            blurRadius: 6,
            // spreadRadius 负值收缩：阴影范围贴紧输入组件，
            // 不再覆盖到底部留白区域
            spreadRadius: -8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
    );
  }

  /// 空状态
  /// 显示会话列表弹窗（切换/删除）
  Future<void> _showSessionList(BuildContext context, AgentLogic logic) async {
    // 确保 Agent 已初始化（会话存储已加载）
    await logic.ensureInitialized();

    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (context) {
        return Obx(() {
          // 订阅消息变化，保证列表在有会话变化时刷新
          logic.service.messages.length;
          final currentId = logic.service.currentSessionId;
          final sessions = logic.service.sessions;
          return Padding(
            padding: AppSpacing.allMD,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Text(
                      '会话列表',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
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
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
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
                            isCurrent ? Icons.forum : Icons.chat_bubble_outline,
                            size: AppTypography.iconMD,
                            color: isCurrent
                                ? Theme.of(context).colorScheme.primary
                                : AppColors.textSecondary,
                          ),
                          title: Text(
                            session.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                  fontWeight: isCurrent
                                      ? AppTypography.weightSemiBold
                                      : FontWeight.w400,
                                ),
                          ),
                          subtitle: Text(
                            _formatSessionTime(session.updatedAt),
                            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                                  color: AppColors.textTertiary,
                                ),
                          ),
                          trailing: IconButton(
                            icon: const Icon(Icons.delete_outline, size: 18),
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
        });
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

/// 回合时间轴（竖向时间线）
/// 把同一回合的 agent 回复文本与工具调用，按执行顺序串成竖向时间轴
class _TurnTimeline extends StatelessWidget {
  final List<AgentMessage> turnMsgs;

  const _TurnTimeline({required this.turnMsgs});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Align(
      alignment: Alignment.centerLeft,
      // 匹配 agent 气泡左间距（8），保持左侧对齐
      child: Padding(
        padding: const EdgeInsets.only(left: 8, top: 4, bottom: 8),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.93,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < turnMsgs.length; i++)
                _buildStep(context, turnMsgs[i], i == turnMsgs.length - 1, i + 1),
            ],
          ),
        ),
      ),
    );
  }

  /// 单个时间轴步骤
  Widget _buildStep(BuildContext context, AgentMessage msg, bool isLast, int stepNumber) {
    final scheme = Theme.of(context).colorScheme;
    final isTool = msg.isToolResult;
    final nodeColor =
        isTool ? _timelineToolColor(msg.toolType) : scheme.primary;

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 时间轴竖线 + 节点圆点（带序号）
          SizedBox(
            width: 20,
            child: Column(
              children: [
                // 节点圆点 + 序号数字
                Container(
                  width: 18,
                  height: 18,
                  margin: EdgeInsets.only(top: 4),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: nodeColor,
                  ),
                  child: Center(
                    child: Text(
                      '$stepNumber',
                      style: TextStyle(
                        fontSize: 9,
                        fontWeight: FontWeight.bold,
                        color: scheme.onPrimary,
                      ),
                    ),
                  ),
                ),
                // 竖线（非最后一步）
                if (!isLast)
                  Expanded(
                    child: Container(
                      width: 2,
                      margin: EdgeInsets.symmetric(vertical: 2),
                      color: scheme.outlineVariant.withValues(alpha: 0.5),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          // 步骤内容
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: isLast ? 0 : AppSpacing.md),
              child: isTool
                  ? (msg.toolType == AgentToolType.confirm
                      ? _buildConfirmNode(context, msg)
                      : _buildToolChip(context, msg))
                  : _buildText(context, msg),
            ),
          ),
        ],
      ),
    );
  }

  /// agent 文本节点（markdown 渲染）
  Widget _buildText(BuildContext context, AgentMessage msg) {
    if (msg.text.trim().isEmpty) {
      return const SizedBox.shrink();
    }
    return AgentMarkdownMessage(text: msg.text);
  }

  /// 确认节点（内联确认/取消按钮）
  /// 待确认：高亮显示问题 + 选项/确认取消按钮
  /// 已选择：disable（不可再点），显示结果
  Widget _buildConfirmNode(BuildContext context, AgentMessage msg) {
    final scheme = Theme.of(context).colorScheme;
    final pending = msg.toolStatus == AgentToolStatus.running;
    final confirmed = msg.toolStatus == AgentToolStatus.done;
    final cancelled = msg.toolStatus == AgentToolStatus.error;
    final question = msg.toolDetail ?? msg.text ?? '';
    final options = msg.confirmOptions ?? const <String>[];

    return Container(
      padding: EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.sm),
      decoration: BoxDecoration(
        color: pending
            ? scheme.primaryContainer.withValues(alpha: 0.6)
            : scheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(
          color: pending ? scheme.primary : scheme.outlineVariant,
          width: pending ? 1.5 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 问题描述
          Row(
            children: [
              Icon(
                pending
                    ? Icons.help_outline
                    : (confirmed ? Icons.check_circle : Icons.cancel),
                size: 16,
                color: pending
                    ? scheme.primary
                    : (confirmed ? AppColors.success : scheme.error),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  pending
                      ? question
                      : (msg.toolDetail ?? '已${confirmed ? "确认" : "取消"}'),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurface,
                        fontWeight: pending ? FontWeight.w600 : FontWeight.w400,
                      ),
                ),
              ),
            ],
          ),
          if (pending && options.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.sm),
            // 多选一：选项列表
            ...options.map((opt) => _buildOptionItem(context, msg, opt)),
          ],
          if (pending && options.isEmpty) ...[
            const SizedBox(height: AppSpacing.sm),
            // 二选一：确认/取消按钮
            Row(
              children: [
                Expanded(
                  child: FilledButton(
                    onPressed: () => _resolve(context, msg.id, '确认'),
                    style: FilledButton.styleFrom(
                      padding: EdgeInsets.symmetric(vertical: 8),
                      backgroundColor: AppColors.success,
                    ),
                    child: const Text('确认'),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => _resolve(context, msg.id, '取消'),
                    style: OutlinedButton.styleFrom(
                      padding: EdgeInsets.symmetric(vertical: 8),
                    ),
                    child: const Text('取消'),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// 单选选项项
  Widget _buildOptionItem(BuildContext context, AgentMessage msg, String option) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.only(bottom: AppSpacing.xs),
      child: SizedBox(
        width: double.infinity,
        child: OutlinedButton.icon(
          onPressed: () => _resolve(context, msg.id, option),
          icon: const Icon(Icons.radio_button_unchecked, size: 16),
          label: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              option,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurface,
                  ),
            ),
          ),
          style: OutlinedButton.styleFrom(
            padding: EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: 8),
            alignment: Alignment.centerLeft,
            backgroundColor: scheme.surface.withValues(alpha: 0.6),
            side: BorderSide(color: scheme.outlineVariant),
          ),
        ),
      ),
    );
  }

  /// 用户选择确认/取消/选项
  void _resolve(BuildContext context, String msgId, String choice) {
    final service = Get.find<AgentService>();
    service.resolveConfirmation(msgId, choice);
  }

  /// 工具节点（胶囊 chip，点击弹详情）
  Widget _buildToolChip(BuildContext context, AgentMessage tool) {
    final scheme = Theme.of(context).colorScheme;
    final color = _timelineToolColor(tool.toolType);
    final isRunning = tool.toolStatus == AgentToolStatus.running;
    final isError = tool.toolStatus == AgentToolStatus.error;

    return GestureDetector(
      onTap: () => _showToolDetailDialog(context, tool),
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: 5),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(AppRadius.sm),
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isError ? Icons.error_outline : _timelineToolIcon(tool.toolType),
              size: 14,
              color: isError ? scheme.error : color,
            ),
            const SizedBox(width: 4),
            Text(
              _timelineToolLabel(tool.toolType),
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: color,
                    fontWeight: FontWeight.w600,
                  ),
          ),
          if (isRunning) ...[
            const SizedBox(width: 4),
            SizedBox(
              width: 10,
              height: 10,
              child: AppLoading(size: AppLoadingSize.small, color: color),
            ),
          ],
        ],
        ),
      ),
    );
  }

  /// 弹框显示工具调用详情（可复制）
  void _showToolDetailDialog(BuildContext context, AgentMessage tool) {
    final buffer = StringBuffer();
    buffer.writeln('工具：${_timelineToolLabel(tool.toolType)}');
    final statusText = switch (tool.toolStatus) {
      AgentToolStatus.running => '执行中',
      AgentToolStatus.done => '完成',
      AgentToolStatus.error => '失败',
      null => '未知',
    };
    buffer.writeln('状态：$statusText');
    if (tool.toolDetail != null && tool.toolDetail!.isNotEmpty) {
      buffer.writeln('详情：');
      buffer.writeln(tool.toolDetail);
    }
    if (tool.downloadStatus != null) {
      buffer.writeln('下载状态：${tool.downloadStatus!.status}');
    }
    final detailText = buffer.toString().trimRight();

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Row(
            children: [
              Icon(_timelineToolIcon(tool.toolType),
                  color: _timelineToolColor(tool.toolType)),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  _timelineToolLabel(tool.toolType),
                  style: const TextStyle(fontSize: 16),
                ),
              ),
            ],
          ),
          content: SingleChildScrollView(
            child: SelectableText(
              detailText,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          actions: [
            TextButton.icon(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: detailText));
                Get.snackbar(
                  '已复制',
                  '工具调用详情已复制到剪贴板',
                  snackPosition: SnackPosition.BOTTOM,
                  duration: const Duration(seconds: 1),
                );
              },
              icon: const Icon(Icons.copy, size: 16),
              label: const Text('复制'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('关闭'),
            ),
          ],
        );
      },
    );
  }

  Color _timelineToolColor(AgentToolType? type) {
    switch (type) {
      case AgentToolType.search:
        return Colors.blue;
      case AgentToolType.download:
        return Colors.orange;
      case AgentToolType.install:
        return Colors.green;
      case AgentToolType.manageApp:
        return Colors.indigo;
      case AgentToolType.appInfo:
        return Colors.teal;
      case AgentToolType.update:
        return Colors.purple;
      case AgentToolType.backup:
        return Colors.brown;
      case AgentToolType.manageDownload:
        return Colors.orange;
      case AgentToolType.theme:
        return Colors.pink;
      case AgentToolType.fdroid:
        return Colors.lightGreen;
      case AgentToolType.webdav:
        return Colors.cyan;
      case AgentToolType.installed:
        return Colors.lime;
      case AgentToolType.config:
        return Colors.blueGrey;
      case null:
      case AgentToolType.confirm:
        return Colors.indigo;
        return Colors.blueGrey;
    }
  }

  IconData _timelineToolIcon(AgentToolType? type) {
    switch (type) {
      case AgentToolType.search:
        return Icons.search;
      case AgentToolType.download:
        return Icons.download;
      case AgentToolType.install:
        return Icons.install_mobile;
      case AgentToolType.manageApp:
        return Icons.apps;
      case AgentToolType.appInfo:
        return Icons.info_outline;
      case AgentToolType.update:
        return Icons.system_update_alt;
      case AgentToolType.backup:
        return Icons.backup_outlined;
      case AgentToolType.manageDownload:
        return Icons.download_for_offline_outlined;
      case AgentToolType.theme:
        return Icons.palette_outlined;
      case AgentToolType.fdroid:
        return Icons.science_outlined;
      case AgentToolType.webdav:
        return Icons.cloud_outlined;
      case AgentToolType.installed:
        return Icons.check_circle_outline;
      case AgentToolType.config:
        return Icons.settings_outlined;
      case null:
      case AgentToolType.confirm:
        return Icons.help_outline;
        return Icons.build;
    }
  }

  String _timelineToolLabel(AgentToolType? type) {
    switch (type) {
      case AgentToolType.search:
        return '🔍 搜索应用';
      case AgentToolType.download:
        return '⬇️ 下载应用';
      case AgentToolType.install:
        return '📦 安装应用';
      case AgentToolType.manageApp:
        return '🗂️ 管理应用';
      case AgentToolType.appInfo:
        return 'ℹ️ 应用详情';
      case AgentToolType.update:
        return '🔄 检查更新';
      case AgentToolType.backup:
        return '💾 备份管理';
      case AgentToolType.manageDownload:
        return '⬇️ 下载管理';
      case AgentToolType.theme:
        return '🎨 主题设置';
      case AgentToolType.fdroid:
        return '🧪 F-Droid 仓库';
      case AgentToolType.webdav:
        return '☁️ WebDAV 同步';
      case AgentToolType.installed:
        return '📱 已安装应用';
      case AgentToolType.config:
        return '⚙️ 配置管理';
      case null:
      case AgentToolType.confirm:
        return '❓ 确认操作';
        return '工具';
    }
  }
}

/// 工具调用聚合容器（圆形卡片堆叠/展开动画）
/// 折叠态：圆形工具卡片堆叠 + 数量，点击展开
/// 展开态：圆形卡片从堆叠位置动画散开排列（最后一个为收起圆形）
/// 运行中的工具：保留工具图标 + 右上角 AppLoading 角标
/// 点击工具圆形：弹框显示调用详情
class _ToolBubble extends StatefulWidget {
  final AgentMessage msg;

  const _ToolBubble({required this.msg});

  @override
  State<_ToolBubble> createState() => _ToolBubbleState();
}

class _ToolBubbleState extends State<_ToolBubble> {
  /// 是否展开
  bool _expanded = false;

  AgentMessage get msg => widget.msg;

  Color get _toolColor => _toolColorOf(msg.toolType);

  Color _toolColorOf(AgentToolType? type) {
    switch (type) {
      case AgentToolType.search:
        return Colors.blue;
      case AgentToolType.download:
        return Colors.orange;
      case AgentToolType.install:
        return Colors.green;
      case AgentToolType.manageApp:
        return Colors.indigo;
      case AgentToolType.appInfo:
        return Colors.teal;
      case AgentToolType.update:
        return Colors.purple;
      case AgentToolType.backup:
        return Colors.brown;
      case AgentToolType.manageDownload:
        return Colors.orange;
      case AgentToolType.theme:
        return Colors.pink;
      case AgentToolType.fdroid:
        return Colors.lightGreen;
      case AgentToolType.webdav:
        return Colors.cyan;
      case AgentToolType.installed:
        return Colors.lime;
      case AgentToolType.config:
        return Colors.blueGrey;
      case null:
      case AgentToolType.confirm:
        return Colors.indigo;
        return Colors.blueGrey;
    }
  }

  /// 工具图标
  IconData _toolIconOf(AgentToolType? type) {
    switch (type) {
      case AgentToolType.search:
        return Icons.search;
      case AgentToolType.download:
        return Icons.download;
      case AgentToolType.install:
        return Icons.install_mobile;
      case AgentToolType.manageApp:
        return Icons.apps;
      case AgentToolType.appInfo:
        return Icons.info_outline;
      case AgentToolType.update:
        return Icons.system_update_alt;
      case AgentToolType.backup:
        return Icons.backup_outlined;
      case AgentToolType.manageDownload:
        return Icons.download_for_offline_outlined;
      case AgentToolType.theme:
        return Icons.palette_outlined;
      case AgentToolType.fdroid:
        return Icons.science_outlined;
      case AgentToolType.webdav:
        return Icons.cloud_outlined;
      case AgentToolType.installed:
        return Icons.check_circle_outline;
      case AgentToolType.config:
        return Icons.settings_outlined;
      case null:
      case AgentToolType.confirm:
        return Icons.help_outline;
        return Icons.build;
    }
  }

  String get _toolLabel => _toolLabelOf(msg.toolType);

  String _toolLabelOf(AgentToolType? type) {
    switch (type) {
      case AgentToolType.search:
        return '🔍 搜索应用';
      case AgentToolType.download:
        return '⬇️ 下载应用';
      case AgentToolType.install:
        return '📦 安装应用';
      case AgentToolType.manageApp:
        return '🗂️ 管理应用';
      case AgentToolType.appInfo:
        return 'ℹ️ 应用详情';
      case AgentToolType.update:
        return '🔄 检查更新';
      case AgentToolType.backup:
        return '💾 备份管理';
      case AgentToolType.manageDownload:
        return '⬇️ 下载管理';
      case AgentToolType.theme:
        return '🎨 主题设置';
      case AgentToolType.fdroid:
        return '🧪 F-Droid 仓库';
      case AgentToolType.webdav:
        return '☁️ WebDAV 同步';
      case AgentToolType.installed:
        return '📱 已安装应用';
      case AgentToolType.config:
        return '⚙️ 配置管理';
      case null:
      case AgentToolType.confirm:
        return '❓ 确认操作';
        return '工具';
    }
  }

  /// 是否有可展示的详情内容
  bool get _hasDetail =>
      (msg.toolDetail != null && msg.toolDetail!.isNotEmpty) ||
      msg.downloadStatus != null;

  @override
  Widget build(BuildContext context) {
    final isRunning = msg.toolStatus == AgentToolStatus.running;

    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        // 工具记录与助手回复同侧（左对齐），宽度与助手气泡一致
        width: double.infinity,
        margin: EdgeInsets.only(bottom: AppSpacing.md),
        padding: EdgeInsets.zero,
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.85,
        ),
        decoration: BoxDecoration(
          color: _toolColor.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(color: _toolColor.withValues(alpha: 0.3)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 标题行（可点击展开/收起，可点击弹窗）
            InkWell(
              onTap: _hasDetail ? () => _toggleExpand() : null,
              borderRadius: BorderRadius.circular(AppRadius.md),
              child: Padding(
                padding: AppSpacing.horizontalMD_verticalSM,
                child: Row(
                  children: [
                    // 状态图标/动画
                    isRunning
                        ? const AppLoading(size: AppLoadingSize.small)
                        : Icon(
                            msg.toolStatus == AgentToolStatus.error
                                ? Icons.error_outline
                                : Icons.check_circle_outline,
                            size: AppTypography.iconSM,
                            color: msg.toolStatus == AgentToolStatus.error
                                ? AppColors.error
                                : _toolColor,
                          ),
                    const SizedBox(width: AppSpacing.md),
                    // 标题文字
                    Expanded(
                      child: Row(
                        children: [
                          Text(
                            _toolLabel,
                            style: Theme.of(context)
                                .textTheme
                                .labelMedium
                                ?.copyWith(
                                  color: _toolColor,
                                  fontWeight: AppTypography.weightSemiBold,
                                ),
                          ),
                          const SizedBox(width: AppSpacing.sm),
                          Text(
                            isRunning ? '执行中...' : '完成',
                            style: Theme.of(context)
                                .textTheme
                                .labelSmall
                                ?.copyWith(
                                  color: msg.toolStatus ==
                                          AgentToolStatus.error
                                      ? AppColors.error
                                      : AppColors.textSecondary,
                                ),
                          ),
                        ],
                      ),
                    ),
                    // 右侧操作区
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // 查看详情按钮（弹窗）
                        if (_hasDetail)
                          GestureDetector(
                            onTap: () => _showDetailDialog(context),
                            child: Icon(
                              Icons.info_outline,
                              size: AppTypography.iconSM,
                              color: _toolColor,
                            ),
                          ),
                        const SizedBox(width: AppSpacing.xs),
                        // 展开/收起指示
                        if (_hasDetail)
                          Icon(
                            _expanded
                                ? Icons.expand_less
                                : Icons.expand_more,
                            size: AppTypography.iconSM,
                            color: AppColors.textSecondary,
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),

            // 展开的详情区域
            if (_expanded && _hasDetail)
              Container(
                width: double.infinity,
                padding: AppSpacing.horizontalMD_verticalSM,
                decoration: BoxDecoration(
                  border: Border(
                    top: BorderSide(
                      color: _toolColor.withValues(alpha: 0.2),
                      width: 1,
                    ),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 工具详情（参数或结果）
                    if (msg.toolDetail != null && msg.toolDetail!.isNotEmpty)
                      Text(
                        msg.toolDetail!,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                            ),
                      ),
                    // 下载进度
                    if (msg.downloadStatus != null)
                      _buildDownloadProgress(context, msg.downloadStatus!),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  void _toggleExpand() {
    setState(() => _expanded = !_expanded);
  }

  /// 弹出工具调用详情对话框（内容可复制）
  void _showDetailDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) {
        // 拼接完整内容：标题 + 状态 + 详情
        final detailText = _buildDetailText();
        return AlertDialog(
          title: Row(
            children: [
              Icon(_toolIconOf(msg.toolType), color: _toolColor),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  _toolLabelOf(msg.toolType),
                  style: const TextStyle(fontSize: 16),
                ),
              ),
            ],
          ),
          content: SingleChildScrollView(
            child: SelectableText(
              detailText,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          actions: [
            TextButton.icon(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: detailText));
                Get.snackbar(
                  '已复制',
                  '工具调用详情已复制到剪贴板',
                  snackPosition: SnackPosition.BOTTOM,
                  duration: const Duration(seconds: 1),
                );
              },
              icon: const Icon(Icons.copy, size: 16),
              label: const Text('复制'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('关闭'),
            ),
          ],
        );
      },
    );
  }

  /// 构建详情文本（用于弹窗显示与复制）
  String _buildDetailText() {
    final buffer = StringBuffer();
    buffer.writeln('工具：${_toolLabelOf(msg.toolType)}');
    final statusText = switch (msg.toolStatus) {
      AgentToolStatus.running => '执行中',
      AgentToolStatus.done => '完成',
      AgentToolStatus.error => '失败',
      null => '未知',
    };
    buffer.writeln('状态：$statusText');
    if (msg.toolDetail != null && msg.toolDetail!.isNotEmpty) {
      buffer.writeln('详情：');
      buffer.writeln(msg.toolDetail);
    }
    if (msg.downloadStatus != null) {
      buffer.writeln('下载状态：${msg.downloadStatus!.status}');
    }
    return buffer.toString().trimRight();
  }

  Widget _buildDownloadProgress(
      BuildContext context, DownloadStatus status) {
    return StreamBuilder<DownloadStatus>(
      stream: status.observer,
      builder: (context, snap) {
        final data = snap.data ?? status;
        final total = data.total;
        final count = data.count;
        final downloading = data.status == DownloadStatus.DOWNLOAD_LOADING;

        final progress = total > 0 ? (count / total).clamp(0.0, 1.0) : 0.0;
        final percent = (progress * 100).toInt();

        return Padding(
          padding: EdgeInsets.only(top: AppSpacing.sm),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(AppRadius.sm),
                child: LinearProgressIndicator(
                  value: progress,
                  minHeight: 6,
                  backgroundColor:
                      Theme.of(context).colorScheme.surfaceContainerHighest,
                  color: Colors.orange,
                ),
              ),
              const SizedBox(height: AppSpacing.xs),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    _formatBytes(count) + ' / ' + _formatBytes(total),
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: AppColors.textSecondary,
                        ),
                  ),
                  Text(
                    downloading
                        ? '$percent%'
                        : (data.status == DownloadStatus.DOWNLOAD_SUCCESS
                            ? '已完成'
                            : '已暂停'),
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: data.status == DownloadStatus.DOWNLOAD_SUCCESS
                              ? AppColors.success
                              : AppColors.textSecondary,
                        ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}
