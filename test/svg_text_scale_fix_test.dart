import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/image/svg_text_scale_fix.dart';

void main() {
  test('shields 徽章：font-size=110 + scale(.1) → 文本 11', () {
    const svg = '<svg width="98" height="20">'
        '<g font-size="110" font-family="Verdana">'
        '<g transform="scale(.1)"><text x="285" y="150">项目状态</text></g>'
        '</g></svg>';
    final fixed = fixSvgTextScale(svg);
    expect(fixed, contains('<text font-size="11" x="285"'));
    // x/y 保持原值，交给 vector_graphics 折算
    expect(fixed, contains('x="285"'));
  });

  test('文本自身字号 × 祖先缩放', () {
    const svg = '<svg><g transform="scale(0.5)">'
        '<text x="10" y="10" font-size="20">Hi</text></g></svg>';
    final fixed = fixSvgTextScale(svg);
    expect(fixed, contains('font-size="10"'));
  });

  test('嵌套缩放累计', () {
    const svg = '<svg><g transform="scale(0.5)"><g transform="scale(0.5)">'
        '<text font-size="40">Hi</text></g></g></svg>';
    final fixed = fixSvgTextScale(svg);
    expect(fixed, contains('font-size="10"'));
  });

  test('无文本 / 旋转 / 非等比缩放：不改动', () {
    expect(fixSvgTextScale('<svg><rect width="1" height="1"/></svg>'),
        '<svg><rect width="1" height="1"/></svg>');
    const rotated =
        '<svg><g transform="rotate(45)"><text font-size="20">Hi</text></g></svg>';
    expect(fixSvgTextScale(rotated), rotated);
    const skewed =
        '<svg><g transform="scale(0.5, 2)"><text font-size="20">Hi</text></g></svg>';
    expect(fixSvgTextScale(skewed), skewed);
  });
}
