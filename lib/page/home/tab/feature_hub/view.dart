/// Scene 式「功能」页：5 组功能网格（plan todo 6）。
///
/// 依据 `.omo/evidence/task-2-scene-reference.md` §2 的 **7→5 分组映射**，
/// Scene 4.7.3 的 7 组（`fragment_nav.xml`）折叠为 GStore 的 5 组：
///
/// | GStore 组 | Scene 来源（§2） |
/// |---|---|
/// | 场景模式 | Scene 组 1 场景模式（同名折叠，per-app 场景/性能档引擎） |
/// | 设备性能 | Scene 组 2 设备性能（同名折叠；含 §2.1 重排的「性能配置」） |
/// | 充电耗电 | Scene 组 3 充电耗电（同名折叠；含 §2.1 重排的「耗电统计」） |
/// | 进阶功能 | Scene 组 4 进阶功能（同名折叠） |
/// | 辅助 | Scene 组 6 辅助功能（语义折叠） |
///
/// **丢弃**：Scene 组 5 Xposed功能（GStore 无 Xposed 等价物，见 §2）；
/// **移出网格**：Scene 组 7 交流反馈（非功能组，迁往「设置」tab，见 §2/§10）。
///
/// 条目级重排（§2.1）：`耗电统计` 由「场景模式」落入「充电耗电」；
/// `性能配置` 由「场景模式」落入「设备性能」。
///
/// **门禁**：AI 助手为网格项，随 `agent_tools` 模块上下线显隐
/// （镜像 `lib/page/home/tab/mine/view.dart` 的 `_agentModuleOnline` 模式）。
///
/// **路由**：每一项都 `context.push` 到 `lib/core/routers.dart` 中**既有**的
/// `AppRoute`——本 todo 不做全量入口枚举（归 todo 10），仅做可靠的首轮映射；
/// 无死链、不新增路由。
///
/// **设计令牌**：颜色/字体一律取自 `Theme.of(context)`（AGENTS.md），
/// 无硬编码颜色/字号；间距/圆角取 `AppSpacing`/`AppRadius` 令牌。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:go_router/go_router.dart';

import 'package:gstore/core/core.dart';

/// 单个功能网格项。
class HubEntry {
  const HubEntry({
    required this.id,
    required this.label,
    required this.icon,
    required this.route,
    this.requiresAgentModule = false,
  });

  /// 稳定标识（用于测试 key `feature_item_<id>`）。
  final String id;

  /// 展示文案。
  final String label;

  /// 展示图标。
  final IconData icon;

  /// 目标路由（`AppRoute` 常量，必须为既有路由）。
  final String route;

  /// 是否受 `agent_tools` 模块门禁（下线时隐藏）。
  final bool requiresAgentModule;
}

/// 一个功能分组（组标题 + 条目）。
class HubGroup {
  const HubGroup({
    required this.id,
    required this.title,
    required this.icon,
    required this.entries,
  });

  /// 稳定标识（用于测试 key `feature_group_<id>`）。
  final String id;

  /// 组标题（§2 的 5 个 GStore 组名）。
  final String title;

  /// 组标题图标。
  final IconData icon;

  /// 组内条目（顺序即渲染顺序）。
  final List<HubEntry> entries;
}

/// 5 组功能定义（7→5 映射，出处 task-2 §2/§2.1）。
///
/// 非 `const`：`AppRoute.*` 为可变 `static String`（`lib/core/routers.dart`），
/// 无法用于常量上下文。
final List<HubGroup> kHubGroups = <HubGroup>[
  // ---- 1. 场景模式（Scene 组 1；核心 = per-app 场景/性能档引擎，WS4）----
  HubGroup(
    id: 'scene',
    title: '场景模式',
    icon: TablerIcons.adjustments,
    entries: <HubEntry>[
      HubEntry(
        id: 'scene_profile',
        label: '应用场景',
        icon: TablerIcons.ruler,
        route: AppRoute.perfProfiles,
      ),
      HubEntry(
        id: 'app_list',
        label: '应用列表',
        icon: TablerIcons.apps,
        route: AppRoute.appList,
      ),
      HubEntry(
        id: 'discovery',
        label: '发现',
        icon: TablerIcons.compass,
        route: AppRoute.discovery,
      ),
    ],
  ),

  // ---- 2. 设备性能（Scene 组 2；性能页整页作为入口 + §2.1 重排的性能配置）----
  HubGroup(
    id: 'performance',
    title: '设备性能',
    icon: TablerIcons.cpu,
    entries: <HubEntry>[
      HubEntry(
        id: 'perf_monitor',
        label: '性能监控',
        icon: TablerIcons.gauge,
        route: AppRoute.perfMonitor,
      ),
      // §2.1 重排：Scene 性能配置（ActivityCpuModes）归「设备性能」。
      HubEntry(
        id: 'perf_profile',
        label: '性能配置',
        icon: TablerIcons.adjustments_alt,
        route: AppRoute.perfProfiles,
      ),
    ],
  ),

  // ---- 3. 充电耗电（Scene 组 3；含 §2.1 重排的耗电统计）----
  // 注：专用充电/耗电页 schema 仍 `pending todo 33`；当前两类统计均落在
  // 既有性能仪表盘（含电池 / 温度 / 电流卡片）——无死链。
  HubGroup(
    id: 'battery',
    title: '充电耗电',
    icon: TablerIcons.battery_charging,
    entries: <HubEntry>[
      HubEntry(
        id: 'battery_monitor',
        label: '电池 / 充电',
        icon: TablerIcons.battery,
        route: AppRoute.perfMonitor,
      ),
      // §2.1 重排：Scene 耗电统计（nav_battery_stats）归「充电耗电」。
      HubEntry(
        id: 'battery_stats',
        label: '耗电统计',
        icon: TablerIcons.bolt,
        route: AppRoute.perfMonitor,
      ),
    ],
  ),

  // ---- 4. 进阶功能（Scene 组 4；GStore 等价入口）----
  HubGroup(
    id: 'advanced',
    title: '进阶功能',
    icon: TablerIcons.stack,
    entries: <HubEntry>[
      HubEntry(
        id: 'backup',
        label: '备份还原',
        icon: TablerIcons.cloud_upload,
        route: AppRoute.backup,
      ),
      HubEntry(
        id: 'module_manage',
        label: '模块管理',
        icon: TablerIcons.package,
        route: AppRoute.moduleManage,
      ),
      HubEntry(
        id: 'it_tools',
        label: '开发工具箱',
        icon: TablerIcons.tools,
        route: AppRoute.itTools,
      ),
      HubEntry(
        id: 'installed_apps',
        label: '已安装应用',
        icon: TablerIcons.brand_android,
        route: AppRoute.installedApps,
      ),
    ],
  ),

  // ---- 5. 辅助（Scene 组 6；GStore 以自身辅助/工具入口承载）----
  HubGroup(
    id: 'auxiliary',
    title: '辅助',
    icon: TablerIcons.help_circle,
    entries: <HubEntry>[
      // AI 助手：随 agent_tools 模块上下线显隐（门禁）。
      HubEntry(
        id: 'agent',
        label: 'AI 助手',
        icon: TablerIcons.sparkles,
        route: AppRoute.agent,
        requiresAgentModule: true,
      ),
      HubEntry(
        id: 'settings',
        label: '设备设置',
        icon: TablerIcons.settings_filled,
        route: AppRoute.settings,
      ),
      HubEntry(
        id: 'log_viewer',
        label: '查看日志',
        icon: TablerIcons.file_text,
        route: AppRoute.logViewer,
      ),
    ],
  ),
];

/// Scene 式「功能」页（三 tab 外壳的「功能」tab 内容）。
///
/// 保持页面状态（tab 切换不销毁：滚动位置保留）。
class FeatureHubPage extends ConsumerStatefulWidget {
  const FeatureHubPage({super.key});

  /// 「功能」tab 标签（三 tab 外壳与页面 AppBar 共用同一文案来源）。
  static const String tabLabel = '功能';

  @override
  ConsumerState<FeatureHubPage> createState() => _FeatureHubPageState();
}

class _FeatureHubPageState extends ConsumerState<FeatureHubPage>
    with AutomaticKeepAliveClientMixin {
  /// agent_tools 模块是否在线（随模块上下线实时更新，控制 AI 助手显隐）。
  bool _agentModuleOnline = false;

  /// agent_tools 模块上下线事件订阅（dispose 取消，防泄漏）。
  StreamSubscription<ModuleEvent>? _agentSub;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    // 监听 agent_tools 模块上下线：下线隐藏 AI 助手网格项，上线恢复
    // （镜像 lib/page/home/tab/mine/view.dart 的 _agentModuleOnline 模式）。
    _agentModuleOnline = ModuleManager.instance.isModuleEnabled('agent_tools');
    _agentSub = ModuleManager.instance.watchModule('agent_tools').listen((_) {
      if (!mounted) return;
      setState(() {
        _agentModuleOnline =
            ModuleManager.instance.isModuleEnabled('agent_tools');
      });
    });
  }

  @override
  void dispose() {
    _agentSub?.cancel();
    super.dispose();
  }

  /// 门禁过滤：隐藏受 `agent_tools` 门禁且当前下线的条目。
  List<HubEntry> _visibleEntries(HubGroup group) {
    return group.entries
        .where((e) => !e.requiresAgentModule || _agentModuleOnline)
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // AutomaticKeepAliveClientMixin 要求
    return Scaffold(
      appBar: AppBar(title: const Text(FeatureHubPage.tabLabel)),
      // SingleChildScrollView + Column：一次性挂载全部 5 组（组数固定、条目少，
      // 且便于 widget 测试用 find.byKey 定位任意条目）。
      body: SingleChildScrollView(
        padding: EdgeInsets.only(
          left: AppSpacing.lg,
          right: AppSpacing.lg,
          top: AppSpacing.lg,
          // 底部避让悬浮导航胶囊（与 MinePage / DashboardPage 一致）。
          bottom: 80 + MediaQuery.of(context).padding.bottom,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            for (var i = 0; i < kHubGroups.length; i++) ...<Widget>[
              if (i > 0) const SizedBox(height: AppSpacing.xl),
              _buildGroup(context, kHubGroups[i]),
            ],
          ],
        ),
      ),
    );
  }

  /// 渲染一个分组（组标题 + 网格）；空组不渲染。
  Widget _buildGroup(BuildContext context, HubGroup group) {
    final entries = _visibleEntries(group);
    if (entries.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        // 组标题
        Row(
          key: Key('feature_group_${group.id}'),
          children: <Widget>[
            Icon(
              group.icon,
              size: AppTypography.iconMD,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(width: AppSpacing.sm),
            Text(
              group.title,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: AppTypography.weightSemiBold,
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        // 网格（4 列，随组内条目自适应高度；自身不滚动）
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          padding: EdgeInsets.zero,
          itemCount: entries.length,
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 4,
            mainAxisSpacing: AppSpacing.md,
            crossAxisSpacing: AppSpacing.md,
            childAspectRatio: 0.82,
          ),
          itemBuilder: (context, index) => _HubTile(entry: entries[index]),
        ),
      ],
    );
  }
}

/// 单个网格磁贴：图标 + 文案，点按 push 到条目路由。
class _HubTile extends StatelessWidget {
  const _HubTile({required this.entry});

  final HubEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return InkWell(
      key: Key('feature_item_${entry.id}'),
      borderRadius: AppRadius.allMD,
      onTap: () => context.push(entry.route),
      child: Padding(
        padding: AppSpacing.onlyVerticalXS,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Container(
              padding: AppSpacing.allSM,
              decoration: BoxDecoration(
                color: scheme.primaryContainer,
                borderRadius: AppRadius.allMD,
              ),
              child: Icon(
                entry.icon,
                size: AppTypography.iconXL,
                color: scheme.onPrimaryContainer,
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              entry.label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurface,
              ),
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}
