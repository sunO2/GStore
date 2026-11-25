import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/design/app_bottom_capsule.dart';
import 'package:gstore/core/design/app_spacing.dart';
import 'package:gstore/page/agent/keyboard_inset_layout.dart';

/// 键盘避让几何回归：
/// 键盘收起/弹出过程中，列表 padding、输入胶囊位置、回底按钮位置都必须
/// 关于键盘高度连续，不能出现“安全区一次性补上”的跳变。
void main() {
  // 独立页 / AI tab 激活：安全区 24 + 外边距 12
  const standaloneInset = 24.0 + AppBottomCapsule.bottomMargin;
  // AI tab 未激活：安全区 + 外边距 + 导航胶囊高 + 呼吸间距
  const navCapsuleVisibleInset = 24.0 +
      AppBottomCapsule.bottomMargin +
      AppBottomCapsule.height +
      AppSpacing.xxl;

  void expectContinuous({
    required double inputBarInset,
    required String label,
  }) {
    const step = 0.5;
    var previous = AgentKeyboardLayout.of(
      keyboard: 600,
      inputBarInset: inputBarInset,
    );
    var previousContentBottom = 600 + previous.list;

    for (var keyboard = 600 - step;
        keyboard >= 0;
        keyboard -= step) {
      final current = AgentKeyboardLayout.of(
        keyboard: keyboard,
        inputBarInset: inputBarInset,
      );
      final contentBottom = keyboard + current.list;

      // 每一小步内各值变化不超过步长（无瞬时跳变）
      expect(
        (current.list - previous.list).abs(),
        lessThanOrEqualTo(step + 1e-9),
        reason: '$label: keyboard=$keyboard 时列表 padding 跳变',
      );
      expect(
        (current.input - previous.input).abs(),
        lessThanOrEqualTo(step + 1e-9),
        reason: '$label: keyboard=$keyboard 时输入胶囊跳变',
      );
      expect(
        (contentBottom - previousContentBottom).abs(),
        lessThanOrEqualTo(step + 1e-9),
        reason: '$label: keyboard=$keyboard 时内容底跳变',
      );

      // 内容底始终在胶囊顶上方保持固定呼吸间距
      expect(
        contentBottom,
        closeTo(
          current.input + AppBottomCapsule.height + AppSpacing.sm,
          1e-9,
        ),
        reason: '$label: keyboard=$keyboard 时内容与胶囊间距不一致',
      );

      previous = current;
      previousContentBottom = contentBottom;
    }
  }

  test('完全收起：列表包含安全区，胶囊停在安全区上', () {
    final layout = AgentKeyboardLayout.of(
      keyboard: 0,
      inputBarInset: standaloneInset,
    );
    expect(layout.message, 0);
    expect(layout.input, standaloneInset);
    expect(
      layout.list,
      standaloneInset + AppBottomCapsule.height + AppSpacing.sm,
    );
    expect(
      layout.button,
      layout.list + AppSpacing.lg,
    );
  });

  test('完全弹出：内容贴键盘顶，列表只剩胶囊占位', () {
    final layout = AgentKeyboardLayout.of(
      keyboard: 300,
      inputBarInset: standaloneInset,
    );
    expect(layout.message, 300);
    expect(layout.input, 300 + AppBottomCapsule.bottomMargin);
    expect(
      layout.list,
      AppBottomCapsule.bottomMargin +
          AppBottomCapsule.height +
          AppSpacing.sm,
    );
    expect(layout.message + layout.list, layout.input + AppBottomCapsule.height + AppSpacing.sm);
  });

  test('独立页 / AI tab 激活：收起全过程连续', () {
    expectContinuous(
      inputBarInset: standaloneInset,
      label: 'standalone',
    );
  });

  test('导航胶囊可见（tab 未激活）：收起全过程连续', () {
    expectContinuous(
      inputBarInset: navCapsuleVisibleInset,
      label: 'navCapsuleVisible',
    );
  });

  test('键盘最后一像素归零时无跳变', () {
    final before = AgentKeyboardLayout.of(
      keyboard: 0.5,
      inputBarInset: standaloneInset,
    );
    final closed = AgentKeyboardLayout.of(
      keyboard: 0,
      inputBarInset: standaloneInset,
    );
    expect((closed.list - before.list).abs(), lessThanOrEqualTo(0.5 + 1e-9));
    expect((closed.input - before.input).abs(), lessThanOrEqualTo(0.5 + 1e-9));
  });
}
