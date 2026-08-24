import 'package:flutter/material.dart';

import 'package:gstore/core/design/design_tokens.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';

/// 版本/环境选择器（通用）：env 独立 chips + 版本列表（随 env 过滤）+ 历史构建入口。
///
/// 数据由调用方提供（脚本渠道从 versionOptions 取），组件只负责渲染与选择回调，
/// 不依赖任何 JSChannel/脚本实现，纯数据驱动，可被其它脚本渠道复用。
class ChannelVersionPickerSheet {
  ChannelVersionPickerSheet._();

  /// 显示选择器；返回用户确认的选择 [VersionSelection] 或 null（取消）。
  ///
  /// [envs] 可选环境列表（如 ['sit','uat','prd','rge','tmp']）
  /// [versions] 版本列表（每项含 version / 所属 envs / 构建数）
  /// [currentEnv] / [currentVersion] 当前选择（高亮）
  /// [onBuildHistory] 历史构建回调（按 version+env 拉取构建列表）
  /// [onBuildSelect] 点历史构建某项 → 下载
  /// [onEnvChanged] 可选：env chip 切换时按需拉取该 env 的版本列表（加载态刷新）；
  /// 不提供 → 维持本地过滤初始 [versions]
  static Future<VersionSelection?> show({
    required BuildContext context,
    required String title,
    required List<String> envs,
    required List<VersionOption> versions,
    String? currentEnv,
    String? currentVersion,
    Future<List<BuildOption>> Function({
      required String version,
      required String env,
    })? onBuildHistory,
    void Function(
      BuildOption build, {
      required String version,
      required String env,
    })? onBuildSelect,
    Future<List<VersionOption>> Function(String env)? onEnvChanged,
  }) {
    return showModalBottomSheet<VersionSelection>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.dialogSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AppRadius.radiusSheet),
        ),
      ),
      builder: (context) => _ChannelVersionPickerSheet(
        title: title,
        envs: envs,
        versions: versions,
        currentEnv: currentEnv,
        currentVersion: currentVersion,
        onBuildHistory: onBuildHistory,
        onBuildSelect: onBuildSelect,
        onEnvChanged: onEnvChanged,
      ),
    );
  }
}

/// 选择结果
class VersionSelection {
  const VersionSelection({required this.env, required this.version});

  final String env;
  final String version;
}

/// 版本选项
class VersionOption {
  const VersionOption({
    required this.version,
    required this.envs,
    required this.buildCount,
  });

  final String version;
  final List<String> envs;
  final int buildCount;
}

/// 历史构建选项
class BuildOption {
  const BuildOption({
    required this.num,
    this.publishedAt,
    this.size,
    this.changelog,
    this.installTimes,
    this.builtBy,
    this.ipaName,
  });

  final int num;
  final DateTime? publishedAt;
  final int? size;
  final String? changelog;
  final int? installTimes;
  final String? builtBy;
  final String? ipaName;
}

class _ChannelVersionPickerSheet extends StatefulWidget {
  const _ChannelVersionPickerSheet({
    required this.title,
    required this.envs,
    required this.versions,
    this.currentEnv,
    this.currentVersion,
    this.onBuildHistory,
    this.onBuildSelect,
    this.onEnvChanged,
  });

  final String title;
  final List<String> envs;
  final List<VersionOption> versions;
  final String? currentEnv;
  final String? currentVersion;
  final Future<List<BuildOption>> Function({
    required String version,
    required String env,
  })? onBuildHistory;

  /// 选中某个历史构建 → 下载；携带该行所属 version/env（多行展开时不复用最近展开）
  final void Function(
    BuildOption build, {
    required String version,
    required String env,
  })? onBuildSelect;
  final Future<List<VersionOption>> Function(String env)? onEnvChanged;

  @override
  State<_ChannelVersionPickerSheet> createState() =>
      _ChannelVersionPickerSheetState();
}

class _ChannelVersionPickerSheetState extends State<_ChannelVersionPickerSheet> {
  late String _selectedEnv;
  String? _selectedVersion;

  /// 历史构建加载状态：key = 'version|env'
  String? _loadingHistoryKey;

  /// 已展开的历史构建列表：key = 'version|env'
  final Map<String, List<BuildOption>> _history = {};

  /// env 切换拉取版本列表的加载态
  bool _loadingEnv = false;

  /// 按 env 缓存的版本列表（onEnvChanged 提供时按需拉取）
  final Map<String, List<VersionOption>> _envVersions = {};

  @override
  void initState() {
    super.initState();
    // 默认选中当前 env（若在可选列表内），否则第一个 env
    _selectedEnv = widget.envs.contains(widget.currentEnv)
        ? widget.currentEnv!
        : (widget.envs.isNotEmpty ? widget.envs.first : '');
    // 初始 versions 属于初始 env（调用方按当前 env 拉取）
    if (widget.onEnvChanged != null) {
      _envVersions[_selectedEnv] = widget.versions;
    }
    // 默认选中当前版本（若属于当前 env）
    if (widget.currentVersion != null &&
        _versionsFor(_selectedEnv)
            .any((v) => v.version == widget.currentVersion)) {
      _selectedVersion = widget.currentVersion;
    }
  }

  /// 当前 env 下的版本列表：onEnvChanged 提供 → 按需拉取缓存；否则过滤初始列表
  List<VersionOption> _versionsFor(String env) {
    if (widget.onEnvChanged != null) {
      return _envVersions[env] ?? const <VersionOption>[];
    }
    return widget.versions.where((v) => v.envs.contains(env)).toList();
  }

  /// 切换 env：onEnvChanged 提供 → 加载态 + 按需拉取刷新版本列表；
  /// 无回调 → 本地过滤初始列表（维持现状）
  Future<void> _selectEnv(String env) async {
    if (env == _selectedEnv) return;
    final onEnvChanged = widget.onEnvChanged;
    setState(() {
      _selectedEnv = env;
      _loadingEnv = onEnvChanged != null;
    });
    if (onEnvChanged == null) {
      if (_selectedVersion != null &&
          !_versionsFor(env).any((v) => v.version == _selectedVersion)) {
        setState(() => _selectedVersion = null);
      }
      return;
    }
    try {
      final list = await onEnvChanged(env);
      if (!mounted) return;
      setState(() {
        _envVersions[env] = list;
        _loadingEnv = false;
        // 保留当前已选 version（若仍在新列表），否则清空
        if (_selectedVersion != null &&
            !list.any((v) => v.version == _selectedVersion)) {
          _selectedVersion = null;
        }
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingEnv = false);
    }
  }

  String _historyKey(String version, String env) => '$version|$env';

  Future<void> _loadHistory(VersionOption version) async {
    final key = _historyKey(version.version, _selectedEnv);
    if (_history.containsKey(key)) {
      // 已加载 → 收起
      setState(() => _history.remove(key));
      return;
    }
    final onBuildHistory = widget.onBuildHistory;
    if (onBuildHistory == null) return;

    setState(() => _loadingHistoryKey = key);
    try {
      final builds = await onBuildHistory(
        version: version.version,
        env: _selectedEnv,
      );
      if (!mounted) return;
      setState(() {
        _history[key] = builds;
        _loadingHistoryKey = null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingHistoryKey = null);
    }
  }

  void _confirm() {
    final version = _selectedVersion;
    if (version == null) return;
    Navigator.of(context).pop(
      VersionSelection(
        env: _selectedEnv,
        version: version,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    final filtered = _versionsFor(_selectedEnv);

    // 弹框限高（屏高 70%）：版本多时列表内部滚动，不顶出屏幕；
    // 确认/取消按钮固定在底部（不随列表滚动，始终可见）。
    final maxHeight = MediaQuery.of(context).size.height * 0.7;

    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ===== 固定头部：标题 + env chips =====
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.xl,
              AppSpacing.xl,
              AppSpacing.xl,
              0,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.title,
                  style: textTheme.titleLarge?.copyWith(
                    fontWeight: AppTypography.weightSemiBold,
                  ),
                ),
                const SizedBox(height: AppSpacing.lg),
                // env 独立选择（chips）
                Text(
                  '环境',
                  style: textTheme.labelLarge?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                Wrap(
                  spacing: AppSpacing.sm,
                  runSpacing: AppSpacing.xs,
                  children: [
                    for (final env in widget.envs)
                      ChoiceChip(
                        label: Text(env),
                        selected: _selectedEnv == env,
                        onSelected: (_) => _selectEnv(env),
                        selectedColor: colorScheme.secondaryContainer,
                        checkmarkColor: colorScheme.onSecondaryContainer,
                        labelStyle: textTheme.labelSmall,
                        visualDensity: VisualDensity.compact,
                        materialTapTargetSize:
                            MaterialTapTargetSize.shrinkWrap,
                        shape: RoundedRectangleBorder(
                          borderRadius:
                              BorderRadius.circular(AppRadius.radiusButton),
                          side: BorderSide(
                            color: _selectedEnv == env
                                ? colorScheme.secondary
                                : colorScheme.outlineVariant,
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: AppSpacing.lg),
                // 版本标题
                Text(
                  '版本',
                  style: textTheme.labelLarge?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
              ],
            ),
          ),

          // ===== 版本列表（独立滚动区）=====
          Expanded(
            child: _loadingEnv
                ? const Center(
                    child: AppLoading(size: AppLoadingSize.small),
                  )
                : filtered.isEmpty
                    ? Center(
                        child: Text(
                          '该环境暂无版本',
                          style: textTheme.bodyMedium?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                      )
                    : ListView.builder(
                        padding: AppSpacing.onlyHorizontalXL,
                        itemCount: filtered.length,
                        itemBuilder: (context, index) {
                          final version = filtered[index];
                          return Column(
                            children: [
                              _VersionRow(
                                version: version,
                                isSelected:
                                    _selectedVersion == version.version,
                                isLoading: _loadingHistoryKey ==
                                    _historyKey(
                                        version.version, _selectedEnv),
                                history: _history[_historyKey(
                                    version.version, _selectedEnv)],
                                onTap: () => setState(() {
                                  _selectedVersion = version.version;
                                }),
                                onHistoryTap: () => _loadHistory(version),
                                onBuildSelect: widget.onBuildSelect == null
                                    ? null
                                    : (build) => widget.onBuildSelect!(
                                          build,
                                          version: version.version,
                                          env: _selectedEnv,
                                        ),
                              ),
                              const Divider(height: 1),
                            ],
                          );
                        },
                      ),
          ),

          // ===== 固定底部：确认/取消按钮（不随列表滚动）=====
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.xl,
                AppSpacing.md,
                AppSpacing.xl,
                AppSpacing.xl,
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  FilledButton(
                    onPressed: _selectedVersion != null ? _confirm : null,
                    child: const Text('确认切换'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 版本行：单选圆点 + 版本号 + "(N 个构建)" + 行尾"历史构建"按钮 + 展开的构建列表
class _VersionRow extends StatelessWidget {
  const _VersionRow({
    required this.version,
    required this.isSelected,
    required this.isLoading,
    required this.history,
    required this.onTap,
    required this.onHistoryTap,
    required this.onBuildSelect,
  });

  final VersionOption version;
  final bool isSelected;
  final bool isLoading;
  final List<BuildOption>? history;
  final VoidCallback onTap;
  final VoidCallback onHistoryTap;
  final void Function(BuildOption build)? onBuildSelect;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Column(
      children: [
        InkWell(
          onTap: onTap,
          child: Padding(
            padding: AppSpacing.onlyVerticalMD,
            child: Row(
              children: [
                // 单选圆点
                Icon(
                  isSelected
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off,
                  size: AppTypography.iconMD,
                  color: isSelected
                      ? colorScheme.primary
                      : colorScheme.outlineVariant,
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    version.version,
                    style: textTheme.bodyLarge?.copyWith(
                      fontWeight: isSelected
                          ? AppTypography.weightMedium
                          : AppTypography.weightRegular,
                      color: isSelected
                          ? colorScheme.primary
                          : colorScheme.onSurface,
                    ),
                  ),
                ),
                Text(
                  '(${version.buildCount} 个构建)',
                  style: textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                // 历史构建按钮
                TextButton(
                  onPressed: isLoading ? null : onHistoryTap,
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: AppSpacing.onlyHorizontalSM,
                    minimumSize: const Size(0, 0),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: isLoading
                      ? const AppLoading(size: AppLoadingSize.small)
                      : Text(
                          history != null ? '收起' : '历史构建',
                          style: textTheme.labelSmall?.copyWith(
                            color: colorScheme.primary,
                          ),
                        ),
                ),
              ],
            ),
          ),
        ),
        // 展开的构建列表（空 → 提示，避免"点了没反应"）
        if (history != null)
          Padding(
            padding: const EdgeInsets.only(
              left: AppTypography.iconMD + AppSpacing.sm,
              bottom: AppSpacing.md,
            ),
            child: history!.isEmpty
                ? Text(
                    '暂无构建记录',
                    style: textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final build in history!)
                        _BuildRow(
                          option: build,
                          onTap: onBuildSelect == null
                              ? null
                              : () => onBuildSelect!(build),
                        ),
                    ],
                  ),
          ),
      ],
    );
  }
}

/// 历史构建行：num / 时间 / 大小 / 更新日志
class _BuildRow extends StatelessWidget {
  const _BuildRow({required this.option, required this.onTap});

  final BuildOption option;
  final VoidCallback? onTap;

  String _formatDateTime(DateTime dt) {
    return '${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} '
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    final meta = [
      if (option.publishedAt != null) _formatDateTime(option.publishedAt!),
      if (option.size != null) formatFileSize(option.size!),
    ].join(' · ');

    return InkWell(
      onTap: onTap,
      borderRadius: AppRadius.allSM,
      child: Padding(
        padding: AppSpacing.onlyVerticalXS,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '构建 #${option.num}',
                    style: textTheme.bodyMedium?.copyWith(
                      fontWeight: AppTypography.weightMedium,
                    ),
                  ),
                ),
                if (meta.isNotEmpty)
                  Text(
                    meta,
                    style: textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
            if (option.changelog != null && option.changelog!.isNotEmpty)
              Padding(
                padding: AppSpacing.onlyTopXS,
                child: Text(
                  option.changelog!,
                  style: textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
