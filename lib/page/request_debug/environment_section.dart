/// 「请求调试」环境分区（plan todo 34）：环境列表 + 键值对编辑 + 当前环境切换。
///
/// 独立文件，便于工作台壳 [RequestDebugPage] 只做最小接线；环境 CRUD 走
/// [RequestDebugStore]（纯内存，随后经 [RequestDebugFacade.save] 落盘）。
///
/// 能力：
/// - 环境列表：名称 + 变量数 + 当前环境标记；
/// - 当前环境切换：点左侧图标设为 / 取消当前环境（`{{var}}` 替换据此取值）；
/// - 键值对编辑：统一底部弹层（名称 + 动态 key/value 行）；
/// - 新建 / 编辑 / 删除（删除经危险二次确认）。
///
/// 设计约束：颜色 / 字号全取主题令牌（[Theme.of]），弹层走统一底部弹层
/// （[AppSheet] / [AppDialogs]），零硬编码颜色 / 字号。
library;

import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';

import 'package:gstore/core/design/app_components.dart';
import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/design/app_sheet.dart';
import 'package:gstore/core/design/app_spacing.dart';
import 'package:gstore/core/design/app_typography.dart';
import 'package:gstore/core/request_debug/request_debug.dart';

// ==================== 分区组件 ====================

/// 环境分区：环境列表 + 当前环境切换 + 键值对编辑。
class RequestDebugEnvironmentSection extends StatefulWidget {
  const RequestDebugEnvironmentSection({super.key, required this.facade});

  /// 窄门面（store CRUD + 落盘）。
  final RequestDebugFacade facade;

  @override
  State<RequestDebugEnvironmentSection> createState() =>
      _RequestDebugEnvironmentSectionState();
}

class _RequestDebugEnvironmentSectionState
    extends State<RequestDebugEnvironmentSection> {
  RequestDebugFacade get _facade => widget.facade;

  // ==================== 动作 ====================

  /// 打开编辑器（[environment] 为 `null` 表示新建）。
  Future<void> _openEditor(DebugEnvironment? environment) async {
    final result = await AppSheet.showCustom<DebugEnvironment>(
      context: context,
      builder: (_) => _EnvironmentEditorSheet(environment: environment),
    );
    if (result == null || !mounted) return;
    if (environment == null) {
      _facade.store.addEnvironment(name: result.name, vars: result.vars);
    } else {
      _facade.store.updateEnvironment(result);
    }
    await _persist();
    if (!mounted) return;
    AppDialogs.showSuccess(environment == null ? '环境已创建' : '环境已保存');
  }

  Future<void> _delete(DebugEnvironment environment) async {
    final ok = await AppDialogs.showConfirmSheet(
      title: '删除环境',
      message: '将删除环境「${environment.name}」及其全部变量，此操作无法撤销。',
      confirmText: '删除',
      isDangerous: true,
    );
    if (ok != true || !mounted) return;
    _facade.store.removeEnvironment(environment.id);
    await _persist();
  }

  /// 当前环境切换：点已激活项则取消激活。
  Future<void> _toggleActive(DebugEnvironment environment) async {
    final isActive = _facade.store.activeEnvironmentId == environment.id;
    _facade.store.setActiveEnvironment(isActive ? null : environment.id);
    await _persist();
  }

  Future<void> _persist() async {
    await _facade.save();
    if (!mounted) return;
    setState(() {});
  }

  // ==================== 构建 ====================

  @override
  Widget build(BuildContext context) {
    final store = _facade.store;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildHeader(context),
        const Divider(height: 1),
        Expanded(
          child: store.environments.isEmpty
              ? _buildEmpty(context)
              : ListView.builder(
                  padding: AppSpacing.onlyVerticalSM,
                  itemCount: store.environments.length,
                  itemBuilder: (context, index) =>
                      _buildEnvironment(context, store.environments[index]),
                ),
        ),
      ],
    );
  }

  Widget _buildHeader(BuildContext context) {
    final theme = Theme.of(context);
    final active = _facade.store.activeEnvironment;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.sm,
        AppSpacing.sm,
        AppSpacing.sm,
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('环境', style: theme.textTheme.titleMedium),
                Text(
                  '当前：${active?.name ?? '未设置'}',
                  key: const Key('request-debug-environment-current'),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            key: const Key('request-debug-environment-add'),
            tooltip: '新建环境',
            icon: const Icon(TablerIcons.plus),
            onPressed: () => _openEditor(null),
          ),
        ],
      ),
    );
  }

  Widget _buildEnvironment(BuildContext context, DebugEnvironment environment) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isActive = _facade.store.activeEnvironmentId == environment.id;
    return ListTile(
      key: Key('request-debug-environment-${environment.id}'),
      leading: IconButton(
        key: Key('request-debug-environment-active-${environment.id}'),
        tooltip: isActive ? '取消当前环境' : '设为当前环境',
        icon: Icon(
          isActive ? TablerIcons.circle_check : TablerIcons.circle,
          color: isActive ? scheme.primary : scheme.onSurfaceVariant,
        ),
        onPressed: () => _toggleActive(environment),
      ),
      title: Text(environment.name),
      subtitle: Text(
        '${environment.vars.length} 个变量${isActive ? ' · 当前环境' : ''}',
        style: theme.textTheme.bodySmall?.copyWith(
          color: isActive ? scheme.primary : scheme.onSurfaceVariant,
        ),
      ),
      onTap: () => _openEditor(environment),
      trailing: PopupMenuButton<String>(
        key: Key('request-debug-environment-menu-${environment.id}'),
        icon: const Icon(TablerIcons.dots),
        onSelected: (value) {
          switch (value) {
            case 'edit':
              _openEditor(environment);
            case 'delete':
              _delete(environment);
          }
        },
        itemBuilder: (_) => [
          PopupMenuItem<String>(
            key: Key('request-debug-environment-edit-${environment.id}'),
            value: 'edit',
            child: const Text('编辑'),
          ),
          PopupMenuItem<String>(
            key: Key('request-debug-environment-delete-${environment.id}'),
            value: 'delete',
            child: const Text('删除'),
          ),
        ],
      ),
    );
  }

  Widget _buildEmpty(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Center(
      child: Padding(
        padding: AppSpacing.allXL,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ColoredAliIcon(
              icon: TablerIcons.variable,
              size: AppTypography.iconXXXL,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(height: AppSpacing.md),
            Text('暂无环境', style: theme.textTheme.titleMedium),
            const SizedBox(height: AppSpacing.sm),
            Text(
              '创建环境后可集中管理 {{变量}} 并一键切换。',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ==================== 环境编辑器 ====================

/// 环境编辑器弹层：名称 + 动态键值对。
class _EnvironmentEditorSheet extends StatefulWidget {
  const _EnvironmentEditorSheet({required this.environment});

  /// 待编辑环境；`null` = 新建。
  final DebugEnvironment? environment;

  @override
  State<_EnvironmentEditorSheet> createState() =>
      _EnvironmentEditorSheetState();
}

class _EnvironmentEditorSheetState extends State<_EnvironmentEditorSheet> {
  late final TextEditingController _name;
  final List<_EnvVarRow> _rows = <_EnvVarRow>[];

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.environment?.name ?? '');
    final vars = widget.environment?.vars ?? const <String, String>{};
    final secretVars =
        widget.environment?.secretVars ?? const <String>{};
    for (final entry in vars.entries) {
      _rows.add(_EnvVarRow(
        key: entry.key,
        value: entry.value,
        secret: secretVars.contains(entry.key),
      ));
    }
    if (_rows.isEmpty) _rows.add(_EnvVarRow());
  }

  @override
  void dispose() {
    _name.dispose();
    for (final row in _rows) {
      row.dispose();
    }
    super.dispose();
  }

  void _addRow() => setState(() => _rows.add(_EnvVarRow()));

  void _removeRow(int index) {
    setState(() {
      _rows.removeAt(index).dispose();
      if (_rows.isEmpty) _rows.add(_EnvVarRow());
    });
  }

  void _save() {
    final name = _name.text.trim();
    if (name.isEmpty) {
      AppDialogs.showError('环境名称不能为空');
      return;
    }
    final vars = <String, String>{};
    final secretVars = <String>{};
    for (final row in _rows) {
      final key = row.key.text.trim();
      if (key.isEmpty) continue;
      vars[key] = row.value.text;
      if (row.secret) secretVars.add(key);
    }
    Navigator.of(context).pop(DebugEnvironment(
      id: widget.environment?.id ?? '',
      name: name,
      vars: vars,
      secretVars: secretVars,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AppSheetScaffold(
      title: widget.environment == null ? '新建环境' : '编辑环境',
      subtitle: '键值对供 {{变量}} 替换使用',
      icon: const ColoredAliIcon(icon: TablerIcons.variable),
      contentPadding: AppSpacing.onlyHorizontalXL,
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: const Key('request-debug-env-name'),
            controller: _name,
            decoration: const InputDecoration(
              labelText: '环境名称',
              hintText: 'dev / staging / prod …',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          Row(
            children: [
              Expanded(
                child: Text('变量', style: theme.textTheme.titleSmall),
              ),
              TextButton.icon(
                key: const Key('request-debug-env-var-add'),
                onPressed: _addRow,
                icon: const Icon(TablerIcons.plus, size: AppTypography.iconSM),
                label: const Text('添加变量'),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          for (var i = 0; i < _rows.length; i++) _buildVarRow(context, i),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('request-debug-env-save'),
          onPressed: _save,
          child: const Text('保存'),
        ),
      ],
    );
  }

  Widget _buildVarRow(BuildContext context, int index) {
    final row = _rows[index];
    return Padding(
      padding: AppSpacing.onlyBottomSM,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: TextField(
              key: Key('request-debug-env-key-$index'),
              controller: row.key,
              decoration: const InputDecoration(
                labelText: '键',
                border: OutlineInputBorder(),
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: TextField(
              key: Key('request-debug-env-value-$index'),
              controller: row.value,
              decoration: const InputDecoration(
                labelText: '值',
                border: OutlineInputBorder(),
              ),
            ),
          ),
          IconButton(
            key: Key('request-debug-env-secret-$index'),
            tooltip: row.secret ? '取消密钥标记' : '标记为密钥（加密存储）',
            icon: Icon(row.secret ? TablerIcons.lock : TablerIcons.lock_open),
            color: row.secret ? Theme.of(context).colorScheme.primary : null,
            onPressed: () => setState(() => row.secret = !row.secret),
          ),
          IconButton(
            key: Key('request-debug-env-remove-$index'),
            tooltip: '删除变量',
            icon: const Icon(TablerIcons.trash),
            onPressed: () => _removeRow(index),
          ),
        ],
      ),
    );
  }
}

/// 环境变量行（一对 key/value 控制器 + 是否密钥标记）。
class _EnvVarRow {
  _EnvVarRow({String key = '', String value = '', this.secret = false})
      : key = TextEditingController(text: key),
        value = TextEditingController(text: value);

  final TextEditingController key;
  final TextEditingController value;

  /// 是否标记为密钥（值走安全存储，见 todo 9）。
  bool secret;

  void dispose() {
    key.dispose();
    value.dispose();
  }
}
