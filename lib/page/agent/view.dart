import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:gstore/core/agent/agent_service.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/http/download/DownloadStatus.dart';

import 'logic.dart';
import 'state.dart';
import 'markdown_message.dart';

class AgentPage extends StatelessWidget {
  const AgentPage({super.key});

  @override
  Widget build(BuildContext context) {
    final logic = Get.put(AgentLogic());
    final state = Get.find<AgentLogic>().state;
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

          // 消息列表
          Expanded(
            child: Obx(() {
              final messages = logic.service.messages;
              if (messages.isEmpty) {
                return _buildEmptyState(context);
              }
              return ListView.builder(
                controller: logic.scrollController,
                padding: AppSpacing.allLG,
                itemCount: messages.length,
                itemBuilder: (context, index) {
                  return _buildMessage(context, messages[index]);
                },
              );
            }),
          ),

          // 输入区
          _buildInputBar(context, logic, state),
        ],
      ),
    );
  }

  /// 空状态
  Widget _buildEmptyState(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.auto_awesome,
            size: AppTypography.iconXXXL,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(height: AppSpacing.lg),
          Text(
            'GStore AI 助手',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: AppTypography.weightSemiBold,
                ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Padding(
            padding: AppSpacing.onlyHorizontalLG,
            child: Text(
              '我可以帮你搜索、下载和安装开源应用。\n试试说："帮我找一个截图工具"',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: AppColors.textSecondary,
                  ),
            ),
          ),
        ],
      ),
    );
  }

  /// 构建消息气泡
  Widget _buildMessage(BuildContext context, AgentMessage msg) {
    if (msg.isUser) {
      return _buildUserBubble(context, msg);
    }
    if (msg.isToolResult) {
      return _buildToolBubble(context, msg);
    }
    return _buildAssistantBubble(context, msg);
  }

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
                            style: TextStyle(
                              fontWeight: isCurrent
                                  ? AppTypography.weightSemiBold
                                  : AppTypography.weightRegular,
                            ),
                          ),
                          subtitle: Text(
                            _formatSessionTime(session.updatedAt),
                            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                                  color: AppColors.textSecondary,
                                ),
                          ),
                          trailing: IconButton(
                            icon: const Icon(Icons.delete_outline,
                                size: AppTypography.iconSM),
                            tooltip: '删除会话',
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

  /// 用户消息气泡
  Widget _buildUserBubble(BuildContext context, AgentMessage msg) {
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        margin: EdgeInsets.only(bottom: AppSpacing.md),
        padding: AppSpacing.horizontalMD_verticalSM,
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.8,
        ),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primaryContainer,
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        child: Text(
          msg.text,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onPrimaryContainer,
              ),
        ),
      ),
    );
  }

  /// AI 文本消息气泡（流式输出时显示光标）
  Widget _buildAssistantBubble(BuildContext context, AgentMessage msg) {
    final isStreaming = msg.text.isEmpty;
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: EdgeInsets.only(bottom: AppSpacing.md),
        padding: AppSpacing.horizontalMD_verticalSM,
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.85,
        ),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        child: isStreaming
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const AppLoading(size: AppLoadingSize.small),
                  const SizedBox(width: AppSpacing.md),
                  Text(
                    '思考中...',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                ],
              )
            : AgentMarkdownMessage(text: msg.text),
      ),
    );
  }

  /// 工具消息气泡（状态图标 + 动画 + 详情，默认折叠可展开）
  Widget _buildToolBubble(BuildContext context, AgentMessage msg) {
    return _ToolBubble(msg: msg);
  }

  /// 输入栏
  Widget _buildInputBar(
      BuildContext context, AgentLogic logic, AgentState state) {
    return Container(
      padding: AppSpacing.allMD,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border(
          top: BorderSide(
            color: Theme.of(context)
                .colorScheme
                .outlineVariant
                .withOpacity(0.3),
          ),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: TextField(
              controller: logic.inputController,
              focusNode: logic.inputFocusNode,
              minLines: 1,
              maxLines: 4,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => logic.sendMessage(),
              decoration: InputDecoration(
                hintText: '输入你的需求...',
                hintStyle: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                filled: true,
                fillColor:
                    Theme.of(context).colorScheme.surfaceContainerHighest,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppRadius.lg),
                  borderSide: BorderSide.none,
                ),
                contentPadding: AppSpacing.horizontalMD_verticalSM,
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Obx(() {
            final sending = state.isGenerating.value;
            return IconButton.filled(
              onPressed: sending ? null : logic.sendMessage,
              icon: sending
                  ? const AppLoading(size: AppLoadingSize.small)
                  : const Icon(Icons.send),
              tooltip: '发送',
            );
          }),
        ],
      ),
    );
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

  /// 切换展开/收起
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

  /// 构建详情文本（含标题、状态、详情内容）
  String _buildDetailText() {
    final buffer = StringBuffer();
    buffer.writeln('工具: ${_toolLabelOf(msg.toolType)}');
    buffer.writeln(
        '状态: ${msg.toolStatus == AgentToolStatus.error ? '失败' : (msg.toolStatus == AgentToolStatus.running ? '执行中' : '完成')}');
    if (msg.toolDetail != null && msg.toolDetail!.isNotEmpty) {
      buffer.writeln();
      buffer.writeln('详情:');
      buffer.writeln(msg.toolDetail);
    }
    final status = msg.downloadStatus;
    if (status != null) {
      buffer.writeln();
      buffer.writeln('下载信息:');
      buffer.writeln('文件名: ${status.fileName}');
      buffer.writeln('已下载: ${_formatBytes(status.count)}');
      buffer.writeln('总大小: ${_formatBytes(status.total)}');
    }
    return buffer.toString();
  }

  /// 下载进度组件
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
                          color: downloading
                              ? Colors.orange
                              : (data.status == DownloadStatus.DOWNLOAD_SUCCESS
                                  ? Colors.green
                                  : AppColors.textSecondary),
                          fontWeight: AppTypography.weightMedium,
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

  /// 格式化文件大小
  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}
