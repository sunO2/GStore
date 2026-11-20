import 'package:flutter/material.dart';

/// 仅平移的页面转场（无缩放、无透明度渐变）。
///
/// 为什么不用默认的 Zoom：整页缩放会让新页文字在每一帧以不同字号重新光栅化，
/// 并反复重建字形图集；淡入淡出又需要整页离屏图层，单帧出现 10ms+ 的
/// `BlitPassGLES`。两者叠加在 90Hz 设备上表现为 push/pop 前 150ms 的 4–6 帧
/// 掉帧（实测与页面内容无关，空页面也一样）。
///
/// 这里只做水平平移：新页从右侧滑入、旧页保持不动。全程 scale = 1、
/// 无 Opacity 层，因此字形图集只构建一次、没有全屏离屏拷贝；
/// 曲线与时长沿用 Material 的 300ms `easeOutCubic` 手感。
class SlidePageTransitionsBuilder extends PageTransitionsBuilder {
  const SlidePageTransitionsBuilder({this.duration});

  /// 覆盖默认转场时长；为空时使用路由自身的 `transitionDuration`（Material 300ms）。
  final Duration? duration;

  @override
  Duration get transitionDuration => duration ?? super.transitionDuration;

  @override
  Widget buildTransitions<T>(
    PageRoute<T>? route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final curved = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    return SlideTransition(
      position: Tween<Offset>(
        begin: const Offset(1, 0),
        end: Offset.zero,
      ).animate(curved),
      child: child,
    );
  }
}
