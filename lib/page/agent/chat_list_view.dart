/// 自绘 AI 对话消息列表（替代 flutter_gen_ai_chat_ui 的 AiChatWidget）。
///
/// 为什么自绘：
/// 库的 AiChatWidget 用 `ListenableBuilder(listenable: controller)` 包住整棵树，
/// 任何一条消息的流式更新（updateMessage → notifyListeners）都会触发**整个
/// 消息列表**重建 → 所有历史消息的 markdown 全部重新解析 → 视觉跳动。
///
/// 本组件改用 **item 缓存 + 签名 diff**：
/// - 消息列表按 turnId 分组（同回合 agent 文本 + 工具调用串成时间轴）；
/// - 每个 item 的渲染结果按"内容签名"缓存成**同一 Widget 实例**；
/// - 流式 chunk 到达时只重建**签名变化**的那个 item，其余 item 返回缓存中
///   的同一实例 → Flutter `Element.updateChild` 因 identical 跳过重建，
///   markdown 不再重复解析，未读历史零重建。
library;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gstore/core/agent/agent_service.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/download/model/download_task.dart';

import 'step_text.dart';
import 'user_bubble.dart';

/// 自绘 AI 对话消息列表。
class AgentChatListView extends StatefulWidget {
  /// 消息列表（AgentService.messages，ValueNotifier 快照）
  final ValueListenable<List<AgentMessage>> messages;

  /// 滚动控制器（由 AgentNotifier 持有，页面手势/自动滚底共用）
  final ScrollController scrollController;

  /// 生成中（底部思考指示器）
  final bool isGenerating;

  /// **流式 UI 挂起标志**（来自 AgentNotifier.uiPaused）。
  /// 用户交互期间（手指按下/滑动阅读）为 true → _sync 只更新数据、
  /// 跳过 setState（UI 冻结，读历史零打扰）；解除时一次性重建。
  final bool uiPaused;

  /// 是否还有更早历史（顶部加载更多）
  final bool hasMoreHistory;

  /// 顶部加载更早历史（reverse 列表滚到顶部时触发）
  final VoidCallback? onLoadMore;

  /// 点击示例问题发送
  final ValueChanged<String>? onSendExample;

  /// 列表底部内边距（悬浮输入栏避让）
  final double bottomPadding;

  const AgentChatListView({
    super.key,
    required this.messages,
    required this.scrollController,
    required this.isGenerating,
    required this.hasMoreHistory,
    this.uiPaused = false,
    this.onLoadMore,
    this.onSendExample,
    this.bottomPadding = 0,
  });

  @override
  State<AgentChatListView> createState() => AgentChatListViewState();
}

/// 列表状态（公开以便测试注入）
class AgentChatListViewState extends State<AgentChatListView> {
  /// 分组后的条目（每组 = 独立消息 或 同回合时间轴）
  List<_ChatItem> _items = const [];

  /// item 缓存：渲染 key → 已构建的 Widget 实例（签名未变时复用同一实例，
  /// Flutter element 因 identical 跳过重建 → 未读历史零重建）
  final Map<String, Widget> _widgetCache = {};

  /// item 签名：渲染 key → 内容签名（text/reasoning/status 等变化时重建）
  final Map<String, String> _signatures = {};

  /// 渲染 key 顺序（reverse 列表：index 0 = 底部最新）
  List<String> _keys = const [];

  /// 待重建的 item key（_sync 标记，_renderItem build 阶段消费）
  final Set<String> _dirtyKeys = {};

  /// 订阅句柄
  VoidCallback? _messagesSub;

  /// 测试辅助：读取 item 缓存快照（key → widget 实例）。
  /// 用于验证"未变化的 item 保持同一 identity（零重建）"。
  @visibleForTesting
  Map<String, Widget> debugWidgetCacheSnapshot() => Map.of(_widgetCache);

  @override
  void initState() {
    super.initState();
    _messagesSub = () => widget.messages.removeListener(_sync);
    widget.messages.addListener(_sync);
    _sync();
  }

  @override
  void didUpdateWidget(covariant AgentChatListView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 消息数据源引用变化（会话切换等）→ 重新订阅
    if (oldWidget.messages != widget.messages) {
      _messagesSub?.call();
      _messagesSub = () => widget.messages.removeListener(_sync);
      widget.messages.addListener(_sync);
      _sync();
      return;
    }
    // 挂起解除（true → false）：一次性重建积攒的 chunk。
    // _sync 在挂起期只更新数据没 setState，这里补一次重建让最新内容上屏。
    if (oldWidget.uiPaused && !widget.uiPaused) {
      if (mounted) setState(() {});
    }
  }

  @override
  void dispose() {
    _messagesSub?.call();
    super.dispose();
  }

  /// 消息变化：重新分组 + 签名 diff，标记需要重建的 item。
  /// **不在回调里构建 widget**（此时 context 不可用 / MediaQuery 报错），
  /// 只记录 key 与签名；_renderItem 在 build 阶段按需重建。
  ///
  /// **挂起态（uiPaused）：数据照常更新（分组/签名/缓存全同步），
  /// 但跳过 setState** → UI 冻结（读历史时最新消息增长不上屏）。
  /// 恢复态由 didUpdateWidget 检测 uiPaused false→false→true 变化触发
  /// 一次性重建。
  void _sync() {
    final msgs = widget.messages.value;
    final grouped = _groupTimeline(msgs);
    // reverse 列表：index 0 = 视觉底部 = 最新消息。
    // 分组结果是时间正序（旧→新），需反转让最新消息位于列表 index 0。
    _items = grouped.reversed.toList();

    final newKeys = <String>[];
    final newSigs = <String, String>{};
    for (final item in _items) {
      final key = item.key;
      final sig = _signatureOf(item);
      newKeys.add(key);
      newSigs[key] = sig;
      if (_signatures[key] != sig) {
        // 签名变化 → 标记待重建（_renderItem 构建时重建该 item）
        _dirtyKeys.add(key);
      }
    }

    // 清理已删除的 key
    if (_widgetCache.length != newKeys.length ||
        _keys.length != newKeys.length) {
      _widgetCache.removeWhere((k, _) => !newSigs.containsKey(k));
      _signatures.removeWhere((k, _) => !newSigs.containsKey(k));
      _dirtyKeys.removeWhere((k) => !newSigs.containsKey(k));
    }

    _keys = newKeys;
    _signatures..clear()..addAll(newSigs);
    // 挂起态冻结 UI；恢复态才重建（didUpdateWidget 兜底，见下）
    if (!widget.uiPaused && mounted) setState(() {});
  }

  /// 渲染一个 item（签名变化的 build 阶段重建，其余复用缓存实例）
  Widget _renderItem(int index) {
    final key = _keys[index];
    if (_dirtyKeys.contains(key)) {
      _dirtyKeys.remove(key);
      final item = _items[index];
      _widgetCache[key] = _buildItemWidget(item);
    }
    return _widgetCache[key]!;
  }

  /// 构建 item widget（按类型：用户气泡 / 时间轴 / 工具聚合）
  Widget _buildItemWidget(_ChatItem item) {
    final msgs = item.turnMsgs ?? [item.msg!];
    final first = msgs.first;
    if (item.turnMsgs == null && first.isUser) {
      return AgentUserBubble(
        text: first.text,
        timeLabel: _formatTime(first.time),
        maxWidth: MediaQuery.of(context).size.width * 0.85,
      );
    }
    if (item.turnMsgs == null && first.isToolResult) {
      return _ToolBubble(msg: first);
    }
    return _TurnTimeline(turnMsgs: msgs);
  }

  @override
  Widget build(BuildContext context) {
    final showWelcome = _items.isEmpty;
    return ListView.builder(
      controller: widget.scrollController,
      reverse: true,
      // 底部避让悬浮输入栏（reverse 列表：bottom padding 在视觉底部，
      // 即 offset 0 一端 = 最新消息下方留白）
      padding: EdgeInsets.only(
        left: 8,
        right: 8,
        top: 8,
        bottom: widget.bottomPadding,
      ),
      // 顶部加载指示（最早历史） + 消息 + 底部生成指示
      itemCount: _items.length + 2,
      cacheExtent: 2000, // 预构建更多 item，减少滚出重建
      itemBuilder: (context, index) {
        if (index == 0) {
          // reverse 列表 index 0 = 视觉底部：生成指示 / 空态
          return _buildBottomIndicator(showWelcome);
        }
        if (index == _items.length + 1) {
          // reverse 列表末尾 = 视觉顶部：加载更早历史
          return _buildTopLoader();
        }
        return _renderItem(index - 1);
      },
    );
  }

  /// 底部（视觉最下）：生成中指示 / 空态欢迎
  Widget _buildBottomIndicator(bool showWelcome) {
    if (showWelcome) {
      return _WelcomeView(onSendExample: widget.onSendExample);
    }
    if (widget.isGenerating) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: const [
            AppLoading(size: AppLoadingSize.small),
            SizedBox(width: 8),
            Text('思考中…', style: TextStyle(fontSize: 13)),
          ],
        ),
      );
    }
    return const SizedBox(height: 8);
  }

  /// 顶部（视觉最上）：加载更早历史触发区
  Widget _buildTopLoader() {
    if (!widget.hasMoreHistory) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Center(
        child: GestureDetector(
          onTap: widget.onLoadMore,
          child: const Text('加载更早消息', style: TextStyle(fontSize: 12)),
        ),
      ),
    );
  }

  // -------------------------------------------------------------------------
  // 分组与签名（纯函数，便于单测）
  // -------------------------------------------------------------------------

  /// 内容签名：参与重建的字段（text/reasoning/状态/进度/确认选项等）
  String _signatureOf(_ChatItem item) {
    final msgs = item.turnMsgs ?? [item.msg!];
    final buf = StringBuffer();
    for (final m in msgs) {
      buf
        ..write(m.id)
        ..write('|u=${m.isUser ? 1 : 0}')
        ..write('|t=${m.isToolResult ? 1 : 0}')
        ..write('|txt=${m.text.length}')
        ..write('|rs=${m.reasoning.length}')
        ..write('|rd=${m.reasoningDone ? 1 : 0}')
        ..write('|ts=${m.toolStatus?.name ?? ''}')
        ..write('|tt=${m.toolType?.name ?? ''}')
        ..write('|td=${m.toolDetail?.length ?? 0}');
      final dl = m.downloadStatus;
      if (dl != null) {
        buf
          ..write('|dl=${dl.status.name}/${dl.received}/${dl.total}')
          ..write('|fn=${dl.fileName}');
      }
      final opts = m.confirmOptions;
      if (opts != null) buf.write('|op=${opts.length}:${opts.join(',')}');
      buf.write(';');
    }
    return buf.toString();
  }

  String _formatTime(DateTime time) {
    final h = time.hour.toString().padLeft(2, '0');
    final m = time.minute.toString().padLeft(2, '0');
    final now = DateTime.now();
    final isToday =
        time.year == now.year && time.month == now.month && time.day == now.day;
    if (isToday) return '$h:$m';
    return '${time.month}/${time.day} $h:$m';
  }
}

/// 分组条目：独立消息 或 同回合时间轴（agent 文本 + 工具消息）
class _ChatItem {
  final AgentMessage? msg;
  final List<AgentMessage>? turnMsgs;

  const _ChatItem({this.msg, this.turnMsgs});

  String get key =>
      turnMsgs != null ? 'timeline_${turnMsgs!.first.id}' : msg!.id;
}

/// 按 turnId 分组：同回合 agent 文本 + 工具消息合并为时间轴；用户消息独立。
List<_ChatItem> _groupTimeline(List<AgentMessage> messages) {
  final result = <_ChatItem>[];
  var currentTurnId = '';
  var currentTurn = <AgentMessage>[];

  void flushTurn() {
    if (currentTurn.isNotEmpty) {
      currentTurn.sort((a, b) => a.seq.compareTo(b.seq));
      result.add(_ChatItem(turnMsgs: List.of(currentTurn)));
      currentTurn = [];
    }
    currentTurnId = '';
  }

  for (final msg in messages) {
    if (msg.isUser) {
      flushTurn();
      result.add(_ChatItem(msg: msg));
    } else {
      final turnId = msg.turnId ?? '';
      if (currentTurn.isNotEmpty &&
          turnId != currentTurnId &&
          turnId.isNotEmpty) {
        flushTurn();
      }
      if (currentTurnId.isEmpty) currentTurnId = turnId;
      currentTurn.add(msg);
    }
  }
  flushTurn();
  return result;
}

/// 空态欢迎页（替代库的 WelcomeMessageConfig）
class _WelcomeView extends StatelessWidget {
  final ValueChanged<String>? onSendExample;

  const _WelcomeView({this.onSendExample});

  static const _questions = [
    '帮我找一个截图工具',
    '帮我下载 Termux',
    '检查我的应用是否有更新',
  ];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 80),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.smart_toy_outlined,
              size: 56, color: scheme.onSurfaceVariant),
          const SizedBox(height: 12),
          Text('GStore AI 助手',
              style: Theme.of(context)
                  .textTheme
                  .titleLarge
                  ?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 24),
          const Text('可以试试这样问我：',
              style: TextStyle(fontSize: 13, color: Colors.grey)),
          const SizedBox(height: 12),
          for (final q in _questions)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: ActionChip(
                label: Text(q),
                onPressed: () => onSendExample?.call(q),
              ),
            ),
        ],
      ),
    );
  }
}

/// 回合时间轴（竖向时间线）：同回合 agent 文本与工具调用按序串联
class _TurnTimeline extends StatelessWidget {
  final List<AgentMessage> turnMsgs;

  const _TurnTimeline({required this.turnMsgs});

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
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
                _buildStep(
                    context, turnMsgs[i], i == turnMsgs.length - 1, i + 1),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStep(
      BuildContext context, AgentMessage msg, bool isLast, int stepNumber) {
    final scheme = Theme.of(context).colorScheme;
    final isTool = msg.isToolResult;
    final nodeColor =
        isTool ? _timelineToolColor(msg.toolType) : scheme.primary;

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 20,
            child: Column(
              children: [
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
          const SizedBox(width: 8),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: isLast ? 0 : 16),
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

  Widget _buildText(BuildContext context, AgentMessage msg) {
    final showReasoning =
        ModuleManager.instance.get<AgentService>()?.model?.showReasoning ??
            true;
    return AgentStepTextBlock(
      text: msg.text,
      reasoning: msg.reasoning,
      reasoningDone: msg.reasoningDone,
      showReasoning: showReasoning,
    );
  }

  Widget _buildConfirmNode(BuildContext context, AgentMessage msg) {
    final scheme = Theme.of(context).colorScheme;
    final pending = msg.toolStatus == AgentToolStatus.running;
    final confirmed = msg.toolStatus == AgentToolStatus.done;
    final question = msg.toolDetail ?? msg.text;
    final options = msg.confirmOptions ?? const <String>[];

    return Container(
      padding: EdgeInsets.symmetric(
          horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: pending
            ? scheme.primaryContainer.withValues(alpha: 0.6)
            : scheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: pending ? scheme.primary : scheme.outlineVariant,
          width: pending ? 1.5 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
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
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  pending
                      ? question
                      : (msg.toolDetail ?? '已${confirmed ? "确认" : "取消"}'),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurface,
                        fontWeight:
                            pending ? FontWeight.w600 : FontWeight.w400,
                      ),
                ),
              ),
            ],
          ),
          if (pending && options.isNotEmpty) ...[
            const SizedBox(height: 8),
            ...options.map((opt) => _buildOptionItem(context, msg, opt)),
          ],
          if (pending && options.isEmpty) ...[
            const SizedBox(height: 8),
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
                const SizedBox(width: 8),
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

  Widget _buildOptionItem(
      BuildContext context, AgentMessage msg, String option) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.only(bottom: 4),
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
            padding:
                EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            alignment: Alignment.centerLeft,
            backgroundColor: scheme.surface.withValues(alpha: 0.6),
            side: BorderSide(color: scheme.outlineVariant),
          ),
        ),
      ),
    );
  }

  void _resolve(BuildContext context, String msgId, String choice) {
    final service = ModuleManager.instance.get<AgentService>();
    if (service == null) {
      AppDialogs.showError('Agent 模块未启用');
      return;
    }
    service.resolveConfirmation(msgId, choice);
  }

  Widget _buildToolChip(BuildContext context, AgentMessage tool) {
    final scheme = Theme.of(context).colorScheme;
    final color = _timelineToolColor(tool.toolType);
    final isRunning = tool.toolStatus == AgentToolStatus.running;
    final isError = tool.toolStatus == AgentToolStatus.error;

    return GestureDetector(
      onTap: () => _showToolDetailDialog(context, tool),
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(8),
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

  void _showToolDetailDialog(BuildContext context, AgentMessage tool) {
    final detailText = _buildToolDetailText(tool, _timelineToolLabel(tool.toolType));

    AppSheet.show<void>(
      context: context,
      title: _timelineToolLabel(tool.toolType),
      icon: Icon(_timelineToolIcon(tool.toolType)),
      iconColor: _timelineToolColor(tool.toolType),
      contentPadding: AppSpacing.onlyHorizontalXL,
      content: SelectableText(
        detailText,
        style: Theme.of(context).textTheme.bodySmall,
      ),
      actions: [
        TextButton.icon(
          onPressed: () {
            Clipboard.setData(ClipboardData(text: detailText));
            AppDialogs.showSuccess('工具调用详情已复制到剪贴板');
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
  }
}

/// 工具调用聚合容器（圆形卡片堆叠/展开动画）——简化版：单工具胶囊卡片
class _ToolBubble extends StatelessWidget {
  final AgentMessage msg;

  const _ToolBubble({required this.msg});

  @override
  Widget build(BuildContext context) {
    final color = _toolColorOf(msg.toolType);
    final isRunning = msg.toolStatus == AgentToolStatus.running;

    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        width: double.infinity,
        margin: EdgeInsets.only(bottom: 16),
        padding: EdgeInsets.zero,
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.85,
        ),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: AppSpacing.horizontalMD_verticalSM,
              child: Row(
                children: [
                  isRunning
                      ? AppLoading(size: AppLoadingSize.small)
                      : Icon(
                          msg.toolStatus == AgentToolStatus.error
                              ? Icons.error_outline
                              : Icons.check_circle_outline,
                          size: 16,
                          color: msg.toolStatus == AgentToolStatus.error
                              ? AppColors.error
                              : color,
                        ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Row(
                      children: [
                        Text(
                          _toolLabelOf(msg.toolType),
                          style: Theme.of(context)
                              .textTheme
                              .labelMedium
                              ?.copyWith(
                                color: color,
                                fontWeight: FontWeight.w600,
                              ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          isRunning ? '执行中...' : '完成',
                          style: Theme.of(context)
                              .textTheme
                              .labelSmall
                              ?.copyWith(
                                color: msg.toolStatus == AgentToolStatus.error
                                    ? AppColors.error
                                    : AppColors.textSecondary,
                              ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            if (msg.downloadStatus != null)
              _buildDownloadProgress(context, msg.downloadStatus!),
          ],
        ),
      ),
    );
  }

  Widget _buildDownloadProgress(BuildContext context, DownloadTask task) {
    final total = task.total;
    final count = task.received;
    final progress = total > 0 ? (count / total).clamp(0.0, 1.0) : 0.0;

    return Padding(
      padding: EdgeInsets.only(top: 8),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: LinearProgressIndicator(
          value: progress,
          minHeight: 6,
          backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
          color: Colors.orange,
        ),
      ),
    );
  }

  static Color _toolColorOf(AgentToolType? type) =>
      _timelineToolColor(type);
}

// ---------------------------------------------------------------------------
// 工具图标/标签/颜色（共享）
// ---------------------------------------------------------------------------

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
    case AgentToolType.snapshot:
      return Colors.deepPurple;
    case null:
    case AgentToolType.confirm:
      return Colors.indigo;
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
    case AgentToolType.snapshot:
      return Icons.camera_alt_outlined;
    case null:
    case AgentToolType.confirm:
      return Icons.help_outline;
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
    case AgentToolType.snapshot:
      return '📸 应用快照';
    case null:
    case AgentToolType.confirm:
      return '❓ 确认操作';
  }
}

String _toolLabelOf(AgentToolType? type) => _timelineToolLabel(type);

String _buildToolDetailText(AgentMessage msg, String label) {
  final buffer = StringBuffer();
  buffer.writeln('工具：$label');
  if (msg.toolName != null && msg.toolName!.isNotEmpty) {
    buffer.writeln('标识：${msg.toolName}');
  }
  final statusText = switch (msg.toolStatus) {
    AgentToolStatus.running => '执行中',
    AgentToolStatus.done => '完成',
    AgentToolStatus.error => '失败',
    null => '未知',
  };
  buffer.writeln('状态：$statusText');
  if (msg.durationMs != null) {
    buffer.writeln('耗时：${(msg.durationMs! / 1000).toStringAsFixed(2)} s');
  }
  final args = msg.toolArgs;
  if (args != null && args.isNotEmpty) {
    buffer.writeln('参数：');
    buffer.writeln(const JsonEncoder.withIndent('  ').convert(args));
  }
  final result = msg.toolResult ?? msg.toolDetail;
  if (result != null && result.isNotEmpty) {
    buffer.writeln('结果：');
    buffer.writeln(result);
  }
  if (msg.downloadStatus != null) {
    buffer.writeln('下载状态：${_downloadStatusLabel(msg.downloadStatus!.status)}');
  }
  return buffer.toString().trimRight();
}

String _downloadStatusLabel(DownloadStatusEnum status) {
  switch (status) {
    case DownloadStatusEnum.queued:
    case DownloadStatusEnum.connecting:
      return '队列中';
    case DownloadStatusEnum.downloading:
      return '下载中';
    case DownloadStatusEnum.paused:
      return '已暂停';
    case DownloadStatusEnum.completed:
      return '已完成';
    case DownloadStatusEnum.failed:
      return '失败';
    case DownloadStatusEnum.cancelled:
      return '已取消';
  }
}