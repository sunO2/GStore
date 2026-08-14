import 'package:flutter/material.dart';
import 'package:gstore/core/design/design_tokens.dart';

/// 列表项入场动画容器：挂载/数据刷新时逐项交错淡入+上滑一次。
///
/// - 单个 [AnimationController]：duration = [AppAnimation.medium] +
///   (itemCount-1) * [AppAnimation.stagger]，initState 时 `forward()` 一次。
/// - 第 i 项用 `CurvedAnimation(controller, Interval(i/n, 1.0, curve))` 包
///   [FadeTransition] + [SlideTransition]（Offset(0, slideOffset) → 0）。
/// - 滚动回收重建：controller 已完成（value=1）→ 新项直接静止可见，不重放。
/// - 数据刷新重放：调用方换 key（如 `ValueKey(数据长度)`）重建 State → 重放。
///
/// 保留 [ListView] 全部原有能力：padding / shrinkWrap / physics / controller
/// 原样透传；`itemBuilder` 内 index 语义不变；separated 模式走
/// [ListView.separated]（需提供 [separatorBuilder]）。
class EntranceList<T> extends StatefulWidget {
  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;
  final EdgeInsets? padding;
  final bool shrinkWrap;
  final ScrollPhysics? physics;
  final ScrollController? controller;

  /// 是否 ListView.separated（需同时提供 [separatorBuilder]）
  final bool separated;
  final IndexedWidgetBuilder? separatorBuilder;

  /// 入场上滑距离（屏幕高度比例）
  final double slideOffset;

  const EntranceList({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    this.padding,
    this.shrinkWrap = false,
    this.physics,
    this.controller,
    this.separated = false,
    this.separatorBuilder,
    this.slideOffset = 0.08,
  }) : assert(!separated || separatorBuilder != null,
            'separated 模式必须提供 separatorBuilder');

  @override
  State<EntranceList<T>> createState() => _EntranceListState<T>();
}

class _EntranceListState<T> extends State<EntranceList<T>>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    // n==0 时 stagger 取 0，避免负时长
    final staggerCount = widget.itemCount > 0 ? widget.itemCount - 1 : 0;
    _controller = AnimationController(
      vsync: this,
      duration: AppAnimation.medium +
          Duration(
            milliseconds:
                staggerCount * AppAnimation.stagger.inMilliseconds,
          ),
    )..forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 第 i 项的入场包装：交错 fade + slide。
  /// n<=0 时不会被调用（ListView itemCount=0）。
  Widget _reveal(BuildContext context, int i) {
    final n = widget.itemCount;
    // i 范围 [0, n-1]，i/n ∈ [0, 1)，Interval 上限恒为 1.0
    final interval = Interval(i / n, 1.0, curve: AppAnimation.curve);
    final reveal = CurvedAnimation(parent: _controller, curve: interval);
    return FadeTransition(
      opacity: reveal,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: Offset(0, widget.slideOffset),
          end: Offset.zero,
        ).animate(reveal),
        child: widget.itemBuilder(context, i),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.separated) {
      return ListView.separated(
        padding: widget.padding,
        shrinkWrap: widget.shrinkWrap,
        physics: widget.physics,
        controller: widget.controller,
        itemCount: widget.itemCount,
        separatorBuilder: widget.separatorBuilder!,
        itemBuilder: _reveal,
      );
    }
    return ListView.builder(
      padding: widget.padding,
      shrinkWrap: widget.shrinkWrap,
      physics: widget.physics,
      controller: widget.controller,
      itemCount: widget.itemCount,
      itemBuilder: _reveal,
    );
  }
}
