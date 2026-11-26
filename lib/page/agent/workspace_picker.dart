import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:gstore/core/core.dart';

/// 弹出工作区选择器（新建应用内工作区 / 选择 SAF 目录）。
///
/// 只负责选择/创建，不负责绑定当前会话；调用方拿到结果后执行
/// [AgentService.setWorkspaceForCurrentSession]。
Future<AgentWorkspaceInfo?> showAgentWorkspacePicker(
  BuildContext context,
  AgentService service,
) async {
  final workspaces = await service.workspaceService.workspaces();
  final current = await service.workspaceService.currentWorkspace();
  if (!context.mounted) return null;

  final selected = await AppSheet.show<String>(
    context: context,
    title: '选择工作区',
    content: Builder(
      builder: (sheetContext) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final item in workspaces)
            ListTile(
              leading: Icon(
                item.id == current.id
                    ? TablerIcons.folder_open
                    : (item.isExternal ? TablerIcons.device_mobile : TablerIcons.folder),
              ),
              title: Text(item.name),
              subtitle: Text(
                item.id == current.id
                    ? '当前会话使用'
                    : (item.isExternal ? '外部目录（SAF）' : '应用内目录'),
              ),
              trailing: item.id == current.id
                  ? Icon(
                      TablerIcons.circle_check,
                      color: Theme.of(context).colorScheme.primary,
                    )
                  : null,
              onTap: () => Navigator.pop(sheetContext, item.id),
            ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(TablerIcons.plus),
            title: const Text('新建应用内工作区'),
            onTap: () => Navigator.pop(sheetContext, '__new__'),
          ),
          ListTile(
            leading: const Icon(TablerIcons.device_mobile),
            title: const Text('选择手机目录（SAF）'),
            subtitle: const Text('授权后可直接读写该目录'),
            onTap: () => Navigator.pop(sheetContext, '__saf__'),
          ),
        ],
      ),
    ),
  );
  if (selected == null || !context.mounted) return null;

  try {
    if (selected == '__new__') {
      return await service.workspaceService.createWorkspace();
    }
    if (selected == '__saf__') {
      final picked = await SafWorkspaceFs.pickDirectory();
      if (picked == null) return null;
      return await service.workspaceService.addSafWorkspace(
        uri: picked.uri,
        name: picked.name,
      );
    }
    for (final item in workspaces) {
      if (item.id == selected) return item;
    }
    return current;
  } catch (error) {
    if (context.mounted) {
      AppDialogs.showError('选择工作区失败：$error');
    }
    return null;
  }
}
