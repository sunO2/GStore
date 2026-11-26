import 'package:flutter/widgets.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';

/// AI 输入框的斜杠快捷指令。
class AgentSlashCommand {
  const AgentSlashCommand({
    required this.id,
    required this.command,
    required this.title,
    required this.subtitle,
    required this.icon,
  });

  final String id;
  final String command;
  final String title;
  final String subtitle;
  final IconData icon;
}

const List<AgentSlashCommand> kAgentSlashCommands = [
  AgentSlashCommand(
    id: 'workspace',
    command: '/workspace',
    title: '切换工作区',
    subtitle: '选择当前会话使用的文件工作区',
    icon: TablerIcons.folder_open,
  ),
  AgentSlashCommand(
    id: 'files',
    command: '/files',
    title: '文件工作区',
    subtitle: '查看文件、预览、导入导出与操作记录',
    icon: TablerIcons.files,
  ),
  AgentSlashCommand(
    id: 'photo',
    command: '/photo',
    title: '照片选择',
    subtitle: '预留：从相册选择图片发送给 AI',
    icon: TablerIcons.photo,
  ),
  AgentSlashCommand(
    id: 'compact',
    command: '/compact',
    title: '压缩上下文',
    subtitle: '把早期消息合并为摘要，释放上下文空间',
    icon: TablerIcons.archive,
  ),
  AgentSlashCommand(
    id: 'new',
    command: '/new',
    title: '新建会话',
    subtitle: '开始一个新的对话',
    icon: TablerIcons.message_plus,
  ),
  AgentSlashCommand(
    id: 'model',
    command: '/model',
    title: '切换模型',
    subtitle: '从当前模型列表中选择要使用的模型',
    icon: TablerIcons.brain,
  ),
  AgentSlashCommand(
    id: 'clear',
    command: '/clear',
    title: '清空当前对话',
    subtitle: '删除当前会话的消息记录',
    icon: TablerIcons.trash,
  ),
  AgentSlashCommand(
    id: 'help',
    command: '/help',
    title: '命令帮助',
    subtitle: '查看所有可用快捷指令',
    icon: TablerIcons.help_circle,
  ),
];

/// 按输入过滤命令：前缀匹配优先，其次标题/描述包含。
List<AgentSlashCommand> filterSlashCommands(String query) {
  final q = query
      .trim()
      .toLowerCase()
      .replaceFirst(RegExp(r'^/+'), '')
      .split(RegExp(r'\s+'))
      .first;
  if (q.isEmpty) return kAgentSlashCommands;

  final prefix = <AgentSlashCommand>[];
  final contains = <AgentSlashCommand>[];
  for (final command in kAgentSlashCommands) {
    final name = command.command.substring(1).toLowerCase();
    if (name.startsWith(q)) {
      prefix.add(command);
    } else if (name.contains(q) ||
        command.title.toLowerCase().contains(q) ||
        command.subtitle.toLowerCase().contains(q)) {
      contains.add(command);
    }
  }
  return [...prefix, ...contains];
}
