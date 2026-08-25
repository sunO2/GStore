import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/theme/theme_data_builder.dart';

/// 底部导航胶囊与页面背景层次测试（深色模式融合修复回归）
///
/// 覆盖：
/// ① 深色主题 navigationBarTheme.backgroundColor 存在，且与 scaffoldBackgroundColor
///    的相对亮度（computeLuminance）差值 > 0.02（胶囊比页面底提升一档层次，不再融合）
/// ② 浅色主题 navigationBarTheme.backgroundColor 存在（磨砂 surface@82% 收编全局主题）

void main() {
  group('navigationBarTheme 与 scaffold 背景层次', () {
    test('深色：导航底色存在且与页面背景亮度差 > 0.02（有层次）', () {
      final dark = ThemeDataBuilder.buildDarkTheme(null);

      final navBg = dark.navigationBarTheme.backgroundColor;
      expect(navBg, isNotNull, reason: '深色主题必须显式提供导航栏底色');

      final navLuminance = navBg!.computeLuminance();
      final scaffoldLuminance = dark.scaffoldBackgroundColor.computeLuminance();
      final delta = (navLuminance - scaffoldLuminance).abs();

      expect(
        delta,
        greaterThan(0.02),
        reason: '深色下导航胶囊底色与 scaffold 背景亮度差 $delta ≤ 0.02，'
            '会导致悬浮胶囊与页面内容背景融层',
      );
    });

    test('浅色：导航底色存在（surface 磨砂收编全局主题）', () {
      final light = ThemeDataBuilder.buildLightTheme(null);

      final navBg = light.navigationBarTheme.backgroundColor;
      expect(navBg, isNotNull);
    });
  });
}
