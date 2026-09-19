import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:gstore/core/design/app_components.dart'
    show AppLoading, AppLoadingSize;
import 'package:gstore/core/design/app_spacing.dart';
import 'package:gstore/core/rust/ModuleBootstrap.dart';

/// 原生模块安装状态聚合流 Provider。
///
/// 桥接 [ModuleBootstrap.states]（`Stream<List<ModuleBootstrapState>>`），
/// 供顶部安装进度条订阅。测试可经 `overrideWith` 注入受控状态流，
/// 从而**无需 FFI、无需网络**即可验证横幅的显示/隐藏。
final moduleBootstrapStatesProvider =
    StreamProvider<List<ModuleBootstrapState>>((ref) {
  return ModuleBootstrap.instance.states;
});

/// 模块名 → 中文名（与模块管理页的原生插件清单保持一致；未收录时原样返回）。
const Map<String, String> moduleInstallLabels = <String, String>{
  'qr': '二维码解码',
  'analyzer': 'APK 分析',
  'repo': 'F-Droid 仓库',
  'download': '下载内核',
  'llm': '本地大模型',
};

/// 返回模块的中文展示名；未收录的模块回退为原始模块名。
String moduleInstallLabel(String module) =>
    moduleInstallLabels[module] ?? module;

/// 顶部轻量「模块安装中」横幅。
///
/// 以 [Stack] 覆盖层方式挂载：第一个子节点是 [child]（被完整保留、全尺寸
/// 布局），叠加层是 `Positioned(top:0,left:0,right:0)` + `SafeArea(bottom:false)`，
/// 因此横幅渲染在状态栏之下且**不位移、不遮挡**应用内容。
///
/// 行为：
/// * 无进行中的安装（`downloading`/`initializing`）→ 不渲染任何覆盖层；
/// * 进行中 → 每个模块一行（中文名 + 进度条 + 阶段文案）；
/// * `ready`/`failed` → 自动隐藏；
/// * 覆盖层包 [IgnorePointer] → 触摸事件穿透到应用。
///
/// 颜色/文字一律取自 [Theme.of]（`colorScheme` / `textTheme`），
/// 遵循 GStore 设计系统约束。
class ModuleInstallBanner extends ConsumerWidget {
  /// 构造横幅；[child] 为被叠加的应用内容。
  const ModuleInstallBanner({super.key, required this.child});

  /// 被覆盖层叠加的应用内容（保持原始布局尺寸）。
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final states = ref.watch(moduleBootstrapStatesProvider).valueOrNull ??
        const <ModuleBootstrapState>[];
    // 仅在安装进行中时可见：ready/failed（以及 absent）一律自动隐藏。
    final active = states
        .where((state) =>
            state.phase == ModuleBootstrapPhase.downloading ||
            state.phase == ModuleBootstrapPhase.initializing)
        .toList(growable: false);

    return Stack(
      children: <Widget>[
        child,
        if (active.isNotEmpty)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              bottom: false,
              child: IgnorePointer(
                child: _ModuleInstallOverlay(states: active),
              ),
            ),
          ),
      ],
    );
  }
}

/// 覆盖层底板：主题色表面 + 每模块一行的紧凑列表。
class _ModuleInstallOverlay extends StatelessWidget {
  const _ModuleInstallOverlay({required this.states});

  final List<ModuleBootstrapState> states;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerHighest,
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.sm,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (var i = 0; i < states.length; i++) ...<Widget>[
              if (i > 0) const SizedBox(height: AppSpacing.sm),
              _ModuleInstallRow(state: states[i]),
            ],
          ],
        ),
      ),
    );
  }
}

/// 单个模块的紧凑安装行：活动指示 + 中文名 + 阶段文案 + 进度条。
class _ModuleInstallRow extends StatelessWidget {
  const _ModuleInstallRow({required this.state});

  final ModuleBootstrapState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final textTheme = theme.textTheme;
    final progress = state.progress;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        const AppLoading(size: AppLoadingSize.small),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      moduleInstallLabel(state.module),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.labelLarge
                          ?.copyWith(color: scheme.onSurface),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Text(
                    _phaseLabel(state),
                    style: textTheme.labelSmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.xs),
              LinearProgressIndicator(
                // progress 为 null → 不定量进度；有值 → 绑定具体比例。
                value: progress,
                minHeight: AppSpacing.xs,
                color: scheme.primary,
                backgroundColor: scheme.primaryContainer,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 阶段文案（下载中带百分比；无进度信息时省略百分比）。
String _phaseLabel(ModuleBootstrapState state) {
  switch (state.phase) {
    case ModuleBootstrapPhase.downloading:
      final progress = state.progress;
      return progress == null
          ? '下载中'
          : '下载中 ${(progress * 100).round()}%';
    case ModuleBootstrapPhase.initializing:
      return '初始化中';
    case ModuleBootstrapPhase.ready:
      return '已就绪';
    case ModuleBootstrapPhase.failed:
      return '安装失败';
    case ModuleBootstrapPhase.absent:
      return '';
  }
}
