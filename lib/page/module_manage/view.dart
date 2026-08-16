import 'package:flutter/material.dart';

import 'package:gstore/core/core.dart';

import 'logic.dart';
import 'state.dart';

/// 模块管理页
///
/// 9 个可开关业务模块（SwitchListTile，切换经 [ModuleManageLogic.toggle]
/// 持久化 + 运行时上下线）+ 8 个系统模块置灰（Switch 禁用，不可关闭）。
/// Obx 渲染 + [ModuleManager.onChange] 实时刷新。
class ModuleManagePage extends StatelessWidget {
  const ModuleManagePage({super.key});

  @override
  Widget build(BuildContext context) {
    // 使用 Get.put 确保 ModuleManageLogic 被初始化
    final logic = Get.put<ModuleManageLogic>(ModuleManageLogic());
    final state = logic.state;

    return Scaffold(
      appBar: AppBar(
        title: const Text('模块管理'),
      ),
      body: Obx(() {
        if (state.loading.value) {
          return const Center(child: AppLoading(size: AppLoadingSize.medium));
        }
        final business = state.entries.where((e) => e.togglable).toList();
        final system = state.entries.where((e) => !e.togglable).toList();
        return ListView(
          children: [
            _buildSectionHeader(context, '业务模块'),
            Card(
              margin: AppSpacing.allLG,
              child: Column(
                children: [
                  for (var i = 0; i < business.length; i++) ...[
                    if (i > 0) const Divider(height: 1),
                    _buildBusinessTile(context, logic, business[i]),
                  ],
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.xxl),
            _buildSectionHeader(context, '系统模块'),
            Card(
              margin: AppSpacing.allLG,
              child: Column(
                children: [
                  for (var i = 0; i < system.length; i++) ...[
                    if (i > 0) const Divider(height: 1),
                    _buildSystemTile(context, system[i]),
                  ],
                ],
              ),
            ),
          ],
        );
      }),
    );
  }

  Widget _buildSectionHeader(BuildContext context, String title) {
    return Padding(
      padding: AppSpacing.onlyHorizontalLG,
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
              fontWeight: AppTypography.weightMedium,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
      ),
    );
  }

  /// 可开关业务模块：SwitchListTile（切换中置灰防连击）
  Widget _buildBusinessTile(
    BuildContext context,
    ModuleManageLogic logic,
    ModuleEntry entry,
  ) {
    return SwitchListTile(
      secondary: Icon(
        _iconOf(entry.name),
        size: AppTypography.iconMD,
        color: Theme.of(context).colorScheme.primary,
      ),
      title: Text(entry.title),
      subtitle: Text(_subtitleOf(entry)),
      value: entry.enabled.value,
      onChanged: logic.state.toggling.contains(entry.name)
          ? null
          : (value) => logic.toggle(entry.name, value),
    );
  }

  /// 系统模块：Switch 禁用置灰（不可关）
  Widget _buildSystemTile(BuildContext context, ModuleEntry entry) {
    return SwitchListTile(
      secondary: Icon(
        Icons.lock_outline,
        size: AppTypography.iconMD,
        color: Theme.of(context).colorScheme.outline,
      ),
      title: Text(entry.title),
      subtitle: Text('${entry.description} · ${entry.note}'),
      value: entry.enabled.value,
      onChanged: null, // 系统模块不可关
    );
  }

  /// 描述 + 依赖展示
  String _subtitleOf(ModuleEntry entry) {
    final deps = entry.dependencies;
    final depText = deps.isEmpty ? '' : ' · 依赖: ${deps.join(', ')}';
    return '${entry.description}$depText';
  }

  /// 模块名 → 图标
  IconData _iconOf(String name) => switch (name) {
        'channel' => Icons.storage,
        'download' => Icons.download,
        'backup' => Icons.backup,
        'webdav' => Icons.cloud,
        'fdroid' => Icons.source,
        'theme' => Icons.palette_outlined,
        'install' => Icons.system_update_alt,
        'aggregate' => Icons.apps,
        'agent_tools' => Icons.smart_toy_outlined,
        _ => Icons.extension,
      };
}
