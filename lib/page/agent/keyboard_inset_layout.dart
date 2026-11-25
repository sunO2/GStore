import 'dart:math' as math;

import 'package:gstore/core/design/app_bottom_capsule.dart';
import 'package:gstore/core/design/app_spacing.dart';

/// AI 输入页的键盘避让几何（距屏幕底部的逻辑像素）。
///
/// 消息区、输入胶囊、消息列表内边距、回到底部按钮全部由同一个
/// [keyboard] 值推导，并且关于 [keyboard] **连续**：
///
/// - 键盘高于安全区时，内容/胶囊贴着键盘顶；
/// - 键盘低于安全区时，胶囊停在安全区上，列表补上未被键盘遮住的安全区，
///   因此不会出现“键盘归零后 padding 突然多出安全区”的跳变。
class AgentKeyboardLayout {
  const AgentKeyboardLayout({
    required this.message,
    required this.input,
    required this.list,
    required this.button,
  });

  /// 消息区底部让位（等于键盘顶）。
  final double message;

  /// 输入胶囊底边距屏幕底部。
  final double input;

  /// 消息列表 bottomPadding（保证内容底距胶囊顶固定呼吸间距）。
  final double list;

  /// “回到底部”按钮底边距屏幕底部。
  final double button;

  factory AgentKeyboardLayout.of({
    required double keyboard,
    required double inputBarInset,
  }) {
    // 键盘高于输入胶囊可停靠位置时贴键盘，否则停在安全区上。
    final input = math.max(
      keyboard + AppBottomCapsule.bottomMargin,
      inputBarInset,
    );
    return AgentKeyboardLayout(
      message: keyboard,
      input: input,
      // 内容底 = keyboard + list；这里反解出 list，使内容底始终等于
      // 输入胶囊顶 + 呼吸间距。
      list: input + AppBottomCapsule.height + AppSpacing.sm - keyboard,
      button:
          input + AppBottomCapsule.height + AppSpacing.sm + AppSpacing.lg,
    );
  }
}
