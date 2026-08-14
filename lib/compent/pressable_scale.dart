import 'package:flutter/material.dart';
import 'package:gstore/core/design/app_animation.dart';

/// 按压缩放反馈：按下缩至 [pressedScale]（默认 0.97），抬起/取消回弹 1.0。
///
/// - [AnimatedScale]（[AppAnimation.fast] + [AppAnimation.curve]）。
/// - 按压状态用裸 [Listener]（onPointerDown/Up/Cancel）维护——不参与手势竞技场，
///   因此与 child 内层 GestureDetector/InkWell 嵌套共存时反馈照常触发
///   （TapGestureRecognizer.onTapDown 需赢下竞技场才触发，会被内层手势饿死）。
/// - tap 手势仅由 [GestureDetector] 转发 [onTap]：child 无自身 onTap 时由外层
///   承接（竞技场唯一成员必胜）；child 已有 onTap 时外层 onTap 传 null 仅做反馈，
///   点击动作仍由内层执行（竞技场单一胜者）。
/// - [enabled] = false 时不注册任何手势：不缩放、不转发 onTap（disabled 状态）。
class PressableScale extends StatefulWidget {
  final Widget child;

  /// 抬起时转发的点击回调（child 无自身 onTap 时使用；
  /// child 已有 onTap 时传 null 仅做按压反馈）
  final VoidCallback? onTap;

  /// 按下缩放目标（默认 0.97）
  final double pressedScale;

  /// 默认 true；false 时不缩放且不响应点击（disabled 状态）
  final bool enabled;

  /// 可选：按下瞬间额外转发（如联动其他 UI）
  final GestureTapDownCallback? onTapDown;

  const PressableScale({
    super.key,
    required this.child,
    this.onTap,
    this.pressedScale = 0.97,
    this.enabled = true,
    this.onTapDown,
  });

  @override
  State<PressableScale> createState() => _PressableScaleState();
}

class _PressableScaleState extends State<PressableScale> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed != value) {
      setState(() => _pressed = value);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scale = (_pressed && widget.enabled) ? widget.pressedScale : 1.0;
    return Listener(
      behavior: HitTestBehavior.opaque,
      // enabled=false：不注册任何回调（无反馈、不转发、不拦截 child 手势）
      onPointerDown: widget.enabled
          ? (event) {
              _setPressed(true);
              widget.onTapDown?.call(TapDownDetails(
                globalPosition: event.position,
                localPosition: event.localPosition,
                kind: event.kind,
              ));
            }
          : null,
      onPointerUp: widget.enabled ? (_) => _setPressed(false) : null,
      onPointerCancel: widget.enabled ? (_) => _setPressed(false) : null,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.enabled ? widget.onTap : null,
        child: AnimatedScale(
          scale: scale,
          duration: AppAnimation.fast,
          curve: AppAnimation.curve,
          child: widget.child,
        ),
      ),
    );
  }
}
