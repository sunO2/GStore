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

class _AgentPageState extends State<AgentPage> {
  late final AgentLogic _logic;
  late final AgentState _state;

  /// 聊天控制器（flutter_gen_ai_chat_ui）
  final ChatMessagesController _chatController = ChatMessagesController();

  /// 当前用户（本机用户）与 AI 用户
  late final ChatUser _currentUser;
  late final ChatUser _aiUser;

  /// 已同步的消息 ID → ChatMessage（增量 diff）
  final Map<String, ChatMessage> _syncedMessages = {};

  /// 工具消息签名（id+status），变化时触发全量聚合重建
  String _lastToolSignature = '';

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

    // 初始化同步（若 service 已加载历史消息）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _onMessagesChanged(_logic.service.messages);
    });
  }

  @override
  void dispose() {
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

  /// 全量重建消息列表（工具消息聚合为容器）
  void _rebuildAll() {
    final msgs = _logic.service.messages;
    // 按持久化顺序重设 createdAt，保证排序正确
    final base = DateTime.fromMillisecondsSinceEpoch(1000);
    final grouped = _groupToolMessages(msgs);
    final list = <ChatMessage>[];
    for (var i = 0; i < grouped.length; i++) {
      final item = grouped[i];
      final cm = item.tools != null
          ? _toToolGroupMessage(item.tools!)
          : _toChatMessage(item.msg!);
      list.add(cm.copyWith(createdAt: base.add(Duration(milliseconds: i + 1))));
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

  /// 将连续的工具消息聚合成组（同回合多个工具调用显示在一个容器）
  /// 返回 [(msg, null)] 普通消息 或 [null, tools] 工具组
  List<({AgentMessage? msg, List<AgentMessage>? tools})> _groupToolMessages(
      List<AgentMessage> messages) {
    final result = <({AgentMessage? msg, List<AgentMessage>? tools})>[];
    var currentTools = <AgentMessage>[];

    void flushTools() {
      if (currentTools.isNotEmpty) {
        result.add((msg: null, tools: List.of(currentTools)));
        currentTools = [];
      }
    }

    for (final msg in messages) {
      if (msg.isToolResult) {
        currentTools.add(msg);
      } else {
        flushTools();
        result.add((msg: msg, tools: null));
      }
    }
    flushTools();
    return result;
  }

  /// 工具组 → 容器 ChatMessage（customBuilder 渲染 _ToolGroupBubble）
  ChatMessage _toToolGroupMessage(List<AgentMessage> tools) {
    // 工具组 id 用首个工具 id
    final firstId = tools.isNotEmpty ? tools.first.id : 'toolgroup';
    return ChatMessage(
      text: '',
      user: _aiUser,
      createdAt: tools.isNotEmpty ? tools.first.time : DateTime.now(),
      customProperties: {'id': 'toolgroup_$firstId'},
      customBuilder: (context, _) => _ToolGroupBubble(tools: tools),
    );
  }

  /// 将 AgentMessage 转换为 ChatMessage
  ChatMessage _toChatMessage(AgentMessage msg) {
    if (msg.isToolResult) {
      // 工具消息：用自定义 widget 渲染工具气泡
      return ChatMessage(
        text: '',
        user: _aiUser,
        createdAt: msg.time,
        customProperties: {'id': msg.id},
        customBuilder: (context, _) => _ToolBubble(msg: msg),
      );
    }
    if (msg.isUser) {
      return ChatMessage(
        text: msg.text,
        user: _currentUser,
        createdAt: msg.time,
        customProperties: {'id': msg.id},
      );
    }
    return ChatMessage(
      text: msg.text,
      user: _aiUser,
      createdAt: msg.time,
      isMarkdown: true,
      customProperties: {'id': msg.id},
    );
  }

  @override
  Widget build(BuildContext context) {
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
                  enableMarkdownStreaming: true,
                  streamingWordByWord: false,
                  loadingConfig: LoadingConfig(
                    isLoading: state.isGenerating.value,
                  ),
                  messageListOptions: MessageListOptions(
                    onLoadMore: () async {
                      // 库自动滚动到顶部时加载更早历史，桥接监听会全量重建保持顺序
                      _logic.loadMoreHistoryIfNeeded();
                    },
                    hasMoreMessages: logic.service.hasMoreHistory,
                    paginationConfig: PaginationConfig(
                      enabled: true,
                      autoLoadOnScroll: true,
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
    final bubbleMaxWidth = MediaQuery.of(context).size.width * 0.85;
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
      showTime: false,
      showUserName: false,
      userTextColor: scheme.onPrimaryContainer,
      aiTextColor: scheme.onSurface,
      textStyle: Theme.of(context).textTheme.bodyMedium,
    );
  }

  /// 输入栏样式（匹配现有风格）
  InputOptions _buildInputOptions(
    BuildContext context,
    AgentLogic logic,
    AgentState state,
  ) {
    final scheme = Theme.of(context).colorScheme;
    return InputOptions.custom(
      textController: logic.inputController,
      textStyle: Theme.of(context).textTheme.bodyMedium,
      sendOnEnter: true,
      decoration: InputDecoration(
        hintText: '输入你的需求...',
        hintStyle: TextStyle(color: scheme.onSurfaceVariant),
        filled: true,
        fillColor: scheme.surfaceContainerHighest,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.lg),
          borderSide: BorderSide.none,
        ),
        contentPadding: AppSpacing.horizontalMD_verticalSM,
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

/// 工具调用聚合容器（圆形卡片堆叠/展开动画）
/// 折叠态：圆形工具卡片堆叠 + 数量，点击展开
/// 展开态：圆形卡片从堆叠位置动画散开排列（最后一个为收起圆形）
/// 运行中的工具：保留工具图标 + 右上角 AppLoading 角标
/// 点击工具圆形：弹框显示调用详情
class _ToolGroupBubble extends StatefulWidget {
  final List<AgentMessage> tools;

  const _ToolGroupBubble({required this.tools});

  @override
  State<_ToolGroupBubble> createState() => _ToolGroupBubbleState();
}

class _ToolGroupBubbleState extends State<_ToolGroupBubble> {
  bool _expanded = false;

  List<AgentMessage> get tools => widget.tools;

  /// 折叠态最多显示的胶囊数
  static const int _maxCollapsedChips = 3;

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
      case null:
        return Colors.blueGrey;
    }
  }

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
      case null:
        return Icons.build;
    }
  }

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
      case null:
        return '工具';
    }
  }

  /// 工具简称（胶囊显示用）
  String _toolShortName(AgentToolType? type) {
    switch (type) {
      case AgentToolType.search:
        return '搜索';
      case AgentToolType.download:
        return '下载';
      case AgentToolType.install:
        return '安装';
      case AgentToolType.manageApp:
        return '管理应用';
      case AgentToolType.appInfo:
        return '详情';
      case AgentToolType.update:
        return '检查更新';
      case AgentToolType.backup:
        return '备份';
      case AgentToolType.manageDownload:
        return '下载管理';
      case AgentToolType.theme:
        return '主题';
      case AgentToolType.fdroid:
        return 'F-Droid';
      case AgentToolType.webdav:
        return 'WebDAV';
      case AgentToolType.installed:
        return '已安装';
      case null:
        return '工具';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      // 匹配 agent 气泡默认左 margin（16），保持左侧对齐；
      // 负上边距抵消 agent 气泡底部 margin，让工具容器紧贴对应的 agent 气泡
      child: Padding(
        padding: const EdgeInsets.only(left: 16, top: -6, bottom: 6),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.85,
          ),
          child: _expanded ? _buildExpanded(context) : _buildCollapsed(context),
        ),
      ),
    );
  }

  /// 折叠态：胶囊 chips 行（工具图标 + 简称 + 计数）
  Widget _buildCollapsed(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // 前 3 个 + 计数胶囊
    final visible = tools.take(_maxCollapsedChips).toList();
    final remaining = tools.length - visible.length;

    return GestureDetector(
      onTap: () => setState(() => _expanded = true),
      behavior: HitTestBehavior.opaque,
      child: Wrap(
        spacing: AppSpacing.sm,
        runSpacing: AppSpacing.xs,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          ...visible.map((tool) => _buildChip(context, tool)),
          if (remaining > 0)
            _buildCountChip(context, remaining),
        ],
      ),
    );
  }

  /// 单个工具胶囊
  Widget _buildChip(BuildContext context, AgentMessage tool) {
    final scheme = Theme.of(context).colorScheme;
    final color = _toolColorOf(tool.toolType);
    final isRunning = tool.toolStatus == AgentToolStatus.running;
    final isError = tool.toolStatus == AgentToolStatus.error;

    return Container(
      padding: EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(AppRadius.circle),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isError ? Icons.error_outline : _toolIconOf(tool.toolType),
            size: 14,
            color: isError ? scheme.error : color,
          ),
          const SizedBox(width: 4),
          Text(
            _toolShortName(tool.toolType),
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: color,
                  fontWeight: FontWeight.w600,
                ),
          ),
          // 运行中 loading 角标
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
    );
  }

  /// 计数胶囊（如 +7）
  Widget _buildCountChip(BuildContext context, int remaining) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: 4),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(AppRadius.circle),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Text(
        '+$remaining',
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
      ),
    );
  }

  /// 展开态：复用 _ToolBubble 条目竖排 + 收起操作
  Widget _buildExpanded(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ...tools.map((tool) => _ToolBubble(msg: tool)),
        // 收起
        GestureDetector(
          onTap: () => setState(() => _expanded = false),
          child: Padding(
            padding: EdgeInsets.symmetric(vertical: AppSpacing.xs),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.expand_less,
                  size: 16,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 4),
                Text(
                  '收起',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// 弹框显示工具调用详情（可复制）
  void _showDetailDialog(BuildContext context, AgentMessage tool) {
    final detailText = _buildDetailText(tool);
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Row(
            children: [
              Icon(_toolIconOf(tool.toolType), color: _toolColorOf(tool.toolType)),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  _toolLabelOf(tool.toolType),
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
  String _buildDetailText(AgentMessage tool) {
    final buffer = StringBuffer();
    buffer.writeln('工具：${_toolLabelOf(tool.toolType)}');
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
    return buffer.toString().trimRight();
  }
}

/// 工具消息气泡
/// 默认折叠（只显示标题），点击展开详情，标题右侧按钮弹出完整内容弹窗（可复制）
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
      case null:
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
      case null:
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
      case null:
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
