import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gstore/page/home/tab/mine/view.dart';
import 'package:gstore/page/home/tab/feature_hub/view.dart';
import 'package:gstore/page/home/tab/dashboard/view.dart';

import 'logic.dart';
import 'state.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/design/app_borders.dart';

/// tab 切换交叉淡入（M3 fadeThrough，无平移）：
/// - 两段式（fromIndex/toIndex 均非空）：源页随 fadeValue 0→0.5 淡出，
///   中点瞬移切换后目标页随 0.5→1 淡入；
/// - 单段式（仅 toIndex 非空，外部瞬移跳转 fallback）：目标页全程 0→1 淡入；
/// - 常态（均空）：当前页 opacity 1，其余 0。
class _TabFadeThrough extends StatelessWidget {
  const _TabFadeThrough({
    required this.index,
    required this.currentIndex,
    required this.fromIndex,
    required this.toIndex,
    required this.fadeValue,
    required this.child,
  });

  /// 本页在 PageView 中的下标
  final int index;

  /// 无切换动画时的当前页（homeProvider.index）
  final int currentIndex;

  /// 两段式交叉淡入的源页（前半段淡出）；null 表示单段淡入/常态
  final int? fromIndex;

  /// 切换目标页（后半段淡入）；null 表示无切换动画
  final int? toIndex;

  /// 淡入淡出进度 0→1（_fadeController.value）
  final double fadeValue;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final from = fromIndex;
    final to = toIndex;
    double opacity;
    if (from != null && to != null) {
      // 两段式交叉：源页 0→0.5 淡出，目标页 0.5→1 淡入（中点瞬移切换）
      if (index == to) {
        opacity = (fadeValue * 2 - 1).clamp(0.0, 1.0);
      } else if (index == from) {
        opacity = (1 - fadeValue * 2).clamp(0.0, 1.0);
      } else {
        opacity = 0.0;
      }
    } else if (index == to) {
      // 外部瞬移跳转 fallback：新页全程 0→1 淡入（无源页淡出，瞬移已完成）
      opacity = fadeValue;
    } else if (index == currentIndex) {
      // 常态：当前页完全显示
      opacity = 1.0;
    } else {
      opacity = 0.0;
    }
    return Opacity(opacity: opacity, child: child);
  }
}

class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage>
    with SingleTickerProviderStateMixin {
  /// 交叉淡入淡出驱动：0→0.5 源页淡出（中点瞬移切换），0.5→1 目标页淡入
  late final AnimationController _fadeController =
      AnimationController(vsync: this, duration: AppAnimation.medium);

  /// 两段式交叉淡入的源页/目标页；均为 null 表示无切换动画
  int? _fromIndex;
  int? _toIndex;

  /// 是否已注册 index 变化监听（listenManual 一次性）
  bool _listeningIndex = false;

  @override
  void initState() {
    super.initState();
    _fadeController.addListener(_onFadeTick);
  }

  @override
  void dispose() {
    _fadeController.dispose();
    super.dispose();
  }

  /// 两段式交叉淡入淡出（底部导航等视图内跳转）：
  /// 记录源页/目标页 → 淡出源页 → 中点瞬移切换 → 淡入目标页。
  void _crossFadeTo(int index) {
    final currentIndex = ref.read(homeProvider).index;
    // 当前可见页：交叉淡入前半段（尚未瞬移）取源页，否则取在途目标页/实际 index
    final current = (_fromIndex != null && _fadeController.value < 0.5)
        ? _fromIndex!
        : (_toIndex ?? currentIndex);
    if (index == current) return;
    _fromIndex = current;
    _toIndex = index;
    _fadeController.forward(from: 0);
  }

  /// 动画逐帧回调：中点一次性瞬移切换；结束时清空淡入状态。
  void _onFadeTick() {
    final v = _fadeController.value;
    final to = _toIndex;
    final notifier = ref.read(homeProvider.notifier);
    if (v >= 0.5 && to != null && notifier.state.index != to) {
      notifier.jumpToPage(to); // 一次性：index 已变后条件不成立
    }
    if (_fadeController.isCompleted && to != null) {
      _fromIndex = null;
      _toIndex = null;
    }
    setState(() {});
  }

  /// 外部瞬移跳转（agent 返回/applist/empty_state）fallback：
  /// 不在交叉淡入流程中时，新页 0→1 单段淡入（瞬移已由 jumpToPage 完成）。
  void _onIndexChanged(int index) {
    if (_toIndex != null) return; // 已在交叉淡入流程中（底部导航路径）
    _fromIndex = null;
    _toIndex = index;
    _fadeController.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final homeState = ref.watch(homeProvider);
    final notifier = ref.read(homeProvider.notifier);
    final index = homeState.index;

    // 外部 jumpToPage（功能网格 / applist 等）落地后触发单段淡入动画。
    // listenManual 一次性注册，避免 build 重复订阅。
    if (!_listeningIndex) {
      _listeningIndex = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ref.listenManual(homeProvider.select((s) => s.index), (prev, next) {
          if (!mounted) return;
          _onIndexChanged(next);
        });
      });
    }

    return Scaffold(
      // 内容延伸到悬浮导航胶囊后方，磨砂才能透出页面内容
      extendBody: true,
      // 禁用自动键盘压缩：输入栏位置由各页用 viewInsets 手动控制
      resizeToAvoidBottomInset: false,
      body: PageView(
        physics: const NeverScrollableScrollPhysics(),
        controller: notifier.controller,
        children: [
          _TabFadeThrough(
            index: HomeTab3.features.tabIndex,
            currentIndex: index,
            fromIndex: _fromIndex,
            toIndex: _toIndex,
            fadeValue: _fadeController.value,
            child: const FeatureHubPage(),
          ),
          _TabFadeThrough(
            index: HomeTab3.home.tabIndex,
            currentIndex: index,
            fromIndex: _fromIndex,
            toIndex: _toIndex,
            fadeValue: _fadeController.value,
            child: const DashboardPage(),
          ),
          _TabFadeThrough(
            index: HomeTab3.settings.tabIndex,
            currentIndex: index,
            fromIndex: _fromIndex,
            toIndex: _toIndex,
            fadeValue: _fadeController.value,
            child: const MinePage(),
          ),
        ],
      ),
      // 悬浮磨砂导航胶囊：BackdropFilter 磨砂 + 半透明主题底 + 圆角悬浮（M3 主题令牌）
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            0,
            AppSpacing.lg,
            AppSpacing.md,
          ),
          child: Container(
            // 细描边层次试验：描边必须在 ClipRRect 外层（内层会被
            // 磨砂/圆角裁掉），圆角半径与内层完全一致避免错位。
            // outlineVariant 深浅色自适应；宽度随主题 borderStyle
            // （AppBorders，无边框档真不绘制）。
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(
                AppRadius.xxl + AppRadius.sm,
              ),
              border: AppBorders.all(
                context,
                color: Theme.of(context)
                    .colorScheme
                    .outlineVariant
                    .withValues(alpha: 0.6),
              ),
            ),
            child: ClipRRect(
              // 大圆角胶囊（高度 64 时近似全圆）
              borderRadius: BorderRadius.circular(
                AppRadius.xxl + AppRadius.sm,
              ),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                child: Builder(builder: (context) {
                  // 局部压缩胶囊高度（M3 默认 80 → 64，更紧凑）。
                  // 必须 copyWith 合并应用主题已定义的 navigationBarTheme，
                  // 否则会整体替换掉 backgroundColor/elevation/indicatorColor/
                  // iconTheme/labelTextStyle，选中态退回 M3 默认（secondaryContainer）。
                  return Theme(
                    data: Theme.of(context).copyWith(
                      navigationBarTheme: Theme.of(context)
                          .navigationBarTheme
                          .copyWith(height: 64),
                    ),
                    child: NavigationBar(
                      selectedIndex: index,
                      // 视图内跳转：两段式交叉淡入（中点由 _onFadeTick 瞬移）
                      onDestinationSelected: _crossFadeTo,
                      destinations: [
                        _buildDestination(
                          index,
                          HomeTab3.features,
                          selectedIcon: TablerIcons.layout_grid_filled,
                          unselectedIcon: TablerIcons.layout_grid,
                          selectedKey: 0,
                          unselectedKey: 1,
                        ),
                        _buildDestination(
                          index,
                          HomeTab3.home,
                          selectedIcon: TablerIcons.home_filled,
                          unselectedIcon: TablerIcons.home,
                          selectedKey: 2,
                          unselectedKey: 3,
                        ),
                        _buildDestination(
                          index,
                          HomeTab3.settings,
                          selectedIcon: TablerIcons.settings_filled,
                          unselectedIcon: TablerIcons.settings,
                          selectedKey: 4,
                          unselectedKey: 5,
                        ),
                      ],
                    ),
                  );
                }),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 单个底部导航 destination：选中项图标微放大（AnimatedScale 包在
  /// AnimatedSwitcher 外，两动画独立叠加：切换淡入淡出 + 缩放），
  /// 文案取自 [HomeTab3] 的稳定标签来源。
  Widget _buildDestination(
    int selectedIndex,
    HomeTab3 tab, {
    required IconData selectedIcon,
    required IconData unselectedIcon,
    required int selectedKey,
    required int unselectedKey,
  }) {
    final isSelected = selectedIndex == tab.tabIndex;
    return NavigationDestination(
      icon: AnimatedScale(
        scale: isSelected ? 1.15 : 1.0,
        duration: AppAnimation.fast,
        curve: AppAnimation.curve,
        child: AnimatedSwitcher(
          duration: AppAnimations.normal,
          child: Icon(
            isSelected ? selectedIcon : unselectedIcon,
            key: ValueKey(isSelected ? selectedKey : unselectedKey),
            size: AppTypography.iconLG,
          ),
        ),
      ),
      label: tab.label,
    );
  }
}
