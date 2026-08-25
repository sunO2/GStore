import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:gstore/page/home/tab/mine/view.dart';
import 'package:gstore/page/home/tab/applist/view.dart';
import 'package:gstore/page/agent/view.dart';
import 'package:gstore/page/home/tab/discovery/view.dart';

import 'logic.dart';
import 'package:gstore/core/icons/Icons.dart';
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

  /// 无切换动画时的当前页（logic.state.index.value）
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

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage>
    with SingleTickerProviderStateMixin {
  late final HomeLogic logic = Get.put(HomeLogic());

  /// 交叉淡入淡出驱动：0→0.5 源页淡出（中点瞬移切换），0.5→1 目标页淡入
  late final AnimationController _fadeController =
      AnimationController(vsync: this, duration: AppAnimation.medium);

  /// ever 监听器（dispose 时回收）
  late Worker _indexWorker;

  /// 两段式交叉淡入的源页/目标页；均为 null 表示无切换动画
  int? _fromIndex;
  int? _toIndex;

  /// agent_tools 模块是否在线（随模块上下线实时更新，控制 AI 助手入口显隐）
  bool _agentModuleEnabled =
      ModuleManager.instance.isModuleEnabled('agent_tools');

  /// agent_tools 模块上下线事件订阅（dispose 取消，防泄漏）
  StreamSubscription<ModuleEvent>? _agentSub;

  @override
  void initState() {
    super.initState();
    _fadeController.addListener(_onFadeTick);
    // 所有 logic.jumpToPage 调用点（agent 返回/applist/empty_state/底部导航瞬移中点）
    // 统一在 index 变化时触发淡入动画；底部导航的两段式交叉淡入由 _crossFadeTo 直接
    // 驱动，其 index 变化发生在 _toIndex 非空期间 → 此处提前返回，避免双触发。
    _indexWorker = ever(logic.state.index, _onIndexChanged);

    // 监听 agent_tools 模块上下线：下线隐藏 AI 助手入口（底部 tab），上线恢复
    _agentSub = ModuleManager.instance.watchModule('agent_tools').listen((_) {
      if (!mounted) return;
      setState(() {
        _agentModuleEnabled =
            ModuleManager.instance.isModuleEnabled('agent_tools');
      });
      // 运行中下线且当前在 AI tab → 跳回来源 tab，防用户困在无入口页面
      if (!_agentModuleEnabled && logic.state.index.value == 2) {
        logic.jumpToPage(logic.state.sourceIndex.value);
      }
    });
  }

  @override
  void dispose() {
    _agentSub?.cancel();
    _indexWorker.dispose();
    _fadeController.dispose();
    super.dispose();
  }

  /// raw(0..3) → display（AI 隐藏时：首页0 发现1 我的3→2）
  int _displayIndex(int raw) =>
      _agentModuleEnabled ? raw : (raw == 3 ? 2 : raw);

  /// display → raw（AI 隐藏时：display2=我的→raw3）
  int _rawIndex(int display) =>
      _agentModuleEnabled ? display : (display == 2 ? 3 : display);

  /// 两段式交叉淡入淡出（底部导航等视图内跳转）：
  /// 记录源页/目标页 → 淡出源页 → 中点瞬移切换 → 淡入目标页。
  void _crossFadeTo(int index) {
    // 当前可见页：交叉淡入前半段（尚未瞬移）取源页，否则取在途目标页/实际 index
    final current = (_fromIndex != null && _fadeController.value < 0.5)
        ? _fromIndex!
        : (_toIndex ?? logic.state.index.value);
    if (index == current) return;
    _fromIndex = current;
    _toIndex = index;
    _fadeController.forward(from: 0);
  }

  /// 动画逐帧回调：中点一次性瞬移切换；结束时清空淡入状态。
  void _onFadeTick() {
    final v = _fadeController.value;
    final to = _toIndex;
    if (v >= 0.5 && to != null && logic.state.index.value != to) {
      logic.jumpToPage(to); // 一次性：index 已变后条件不成立
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
    // AI 助手 tab 时拦截系统返回：回到来源 tab（而非退出 app）
    // canPop 动态跟随 index：非 AI tab 返回键正常退出
    return Obx(() {
      final isAiTab = logic.state.index.value == 2;
      return PopScope(
        canPop: !isAiTab,
        onPopInvokedWithResult: (didPop, result) {
          if (!didPop && isAiTab) {
            logic.jumpToPage(logic.state.sourceIndex.value);
          }
        },
        child: Scaffold(
          // 内容延伸到悬浮导航胶囊后方，磨砂才能透出页面内容
          extendBody: true,
          // 禁用自动键盘压缩：输入栏位置由各页用 viewInsets 手动控制
          // （AI 悬浮输入栏需精确贴键盘，Scaffold 压缩会导致双倍偏移）
          resizeToAvoidBottomInset: false,
          body: PageView(
            physics: const NeverScrollableScrollPhysics(),
            controller: logic.controller,
            children: [
              _TabFadeThrough(
                index: 0,
                currentIndex: logic.state.index.value,
                fromIndex: _fromIndex,
                toIndex: _toIndex,
                fadeValue: _fadeController.value,
                child: const ApplistPage(),
              ),
              _TabFadeThrough(
                index: 1,
                currentIndex: logic.state.index.value,
                fromIndex: _fromIndex,
                toIndex: _toIndex,
                fadeValue: _fadeController.value,
                child: const DiscoveryPage(),
              ),
              _TabFadeThrough(
                index: 2,
                currentIndex: logic.state.index.value,
                fromIndex: _fromIndex,
                toIndex: _toIndex,
                fadeValue: _fadeController.value,
                child: const AgentPage(isTabEmbedded: true),
              ),
              _TabFadeThrough(
                index: 3,
                currentIndex: logic.state.index.value,
                fromIndex: _fromIndex,
                toIndex: _toIndex,
                fadeValue: _fadeController.value,
                child: const MinePage(),
              ),
            ],
          ),
          // 悬浮磨砂导航胶囊：BackdropFilter 磨砂 + 半透明主题底 + 圆角悬浮（M3 主题令牌）
          // AI 助手页激活时下沉滑出（聚焦模式，由输入栏左侧"返回"按钮接管导航）
          bottomNavigationBar: Obx(() {
            final isAiTab = logic.state.index.value == 2;
            return AnimatedSlide(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
              offset: isAiTab ? const Offset(0, 1.2) : Offset.zero,
              child: ExcludeSemantics(
                excluding: isAiTab,
                child: IgnorePointer(
                  ignoring: isAiTab,
                  child: SafeArea(
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
                            child: Obx(() {
                              // 局部压缩胶囊高度（M3 默认 80 → 64，更紧凑；主题其他属性不变）
                              return Theme(
                                data: Theme.of(context).copyWith(
                                  navigationBarTheme:
                                      const NavigationBarThemeData(height: 64),
                                ),
                                child: NavigationBar(
                                  selectedIndex:
                                      _displayIndex(logic.state.index.value),
                                  onDestinationSelected: (index) {
                                    // 视图内跳转：两段式交叉淡入（中点由 _onFadeTick 瞬移）
                                    // display 下标 → raw 下标（AI 隐藏时 display2=我的→raw3）
                                    _crossFadeTo(_rawIndex(index));
                                  },
                                  destinations: [
                                    NavigationDestination(
                                      // 选中项图标微放大（AnimatedScale 包在 AnimatedSwitcher 外，
                                      // 两动画独立叠加：切换淡入淡出 + 缩放）
                                      icon: AnimatedScale(
                                        scale: (logic.state.index.value == 0)
                                            ? 1.15
                                            : 1.0,
                                        duration: AppAnimation.fast,
                                        curve: AppAnimation.curve,
                                        child: AnimatedSwitcher(
                                          duration: AppAnimations.normal,
                                          child: ColorFiltered(
                                            // AliIcon 是 COLR 彩色字体，不响应 IconTheme 颜色，强制染色
                                            colorFilter: ColorFilter.mode(
                                              (logic.state.index.value == 0)
                                                  ? Theme.of(context)
                                                      .colorScheme
                                                      .primary
                                                  : Theme.of(context)
                                                      .colorScheme
                                                      .onSurfaceVariant,
                                              BlendMode.srcATop,
                                            ),
                                            child: Icon(
                                              (logic.state.index.value == 0)
                                                  ? AliIcon.appStoreActive
                                                  : AliIcon.appStore,
                                              key: ValueKey(
                                                logic.state.index.value == 0
                                                    ? 0
                                                    : 1,
                                              ),
                                              size: AppTypography.iconLG,
                                            ),
                                          ),
                                        ),
                                      ),
                                      label: "首页",
                                    ),
                                    NavigationDestination(
                                      icon: AnimatedScale(
                                        scale: (logic.state.index.value == 1)
                                            ? 1.15
                                            : 1.0,
                                        duration: AppAnimation.fast,
                                        curve: AppAnimation.curve,
                                        child: AnimatedSwitcher(
                                          duration: AppAnimations.normal,
                                          child: (logic.state.index.value == 1)
                                              ? const Icon(Icons.explore,
                                                  key: ValueKey(2))
                                              : const Icon(
                                                  Icons.explore_outlined,
                                                  key: ValueKey(3)),
                                        ),
                                      ),
                                      label: "发现",
                                    ),
                                    // AI 助手入口随 agent_tools 模块上下线显隐
                                    if (_agentModuleEnabled)
                                      NavigationDestination(
                                        icon: AnimatedScale(
                                          scale: (logic.state.index.value == 2)
                                              ? 1.15
                                              : 1.0,
                                          duration: AppAnimation.fast,
                                          curve: AppAnimation.curve,
                                          child: AnimatedSwitcher(
                                            duration: AppAnimations.normal,
                                            child: (logic.state.index.value ==
                                                    2)
                                                ? const Icon(Icons.smart_toy,
                                                    key: ValueKey(6))
                                                : const Icon(
                                                    Icons.smart_toy_outlined,
                                                    key: ValueKey(7)),
                                          ),
                                        ),
                                        label: "AI 助手",
                                      ),
                                    NavigationDestination(
                                      icon: AnimatedScale(
                                        scale: (logic.state.index.value == 3)
                                            ? 1.15
                                            : 1.0,
                                        duration: AppAnimation.fast,
                                        curve: AppAnimation.curve,
                                        child: AnimatedSwitcher(
                                          duration: AppAnimations.normal,
                                          child: (logic.state.index.value == 3)
                                              ? const Icon(Icons.person,
                                                  key: ValueKey(4))
                                              : const Icon(Icons.person_outline,
                                                  key: ValueKey(5)),
                                        ),
                                      ),
                                      label: "我的",
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
                ),
              ),
            );
          }),
        ),
      );
    });
  }
}
