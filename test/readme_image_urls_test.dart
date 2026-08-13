import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/utils/unit.dart';
import 'package:gstore/page/detail/widgets.dart';

void main() {
  group('resolveReadmeImageUrls', () {
    const base = 'https://raw.githubusercontent.com/user/repo/refs/heads/main/';

    test('相对路径图片拼接 base', () {
      expect(
        resolveReadmeImageUrls('![img](images/x.png)', base),
        '![img](${base}images/x.png)',
      );
    });

    test('./ 前缀相对路径拼接 base', () {
      expect(
        resolveReadmeImageUrls('![a](./b.png)', base),
        '![a](${base}./b.png)',
      );
    });

    test('../ 前缀相对路径拼接 base', () {
      expect(
        resolveReadmeImageUrls('![a](../img/b.png)', base),
        '![a](${base}../img/b.png)',
      );
    });

    test('绝对 URL 图片不动', () {
      const src = '![a](https://example.com/x.png)';
      expect(resolveReadmeImageUrls(src, base), src);
    });

    test('raw.githubusercontent.com 绝对 URL 不动', () {
      const src = '![a](https://raw.githubusercontent.com/o/r/main/x.png)';
      expect(resolveReadmeImageUrls(src, base), src);
    });

    test('data: URI 图片不动', () {
      const src = '![a](data:image/png;base64,iVBORw0KGgo=)';
      expect(resolveReadmeImageUrls(src, base), src);
    });

    test('普通链接（非图片）不动', () {
      const src = '[text](https://example.com/doc)';
      expect(resolveReadmeImageUrls(src, base), src);
    });

    test('混合文本只替换图片', () {
      const input = '标题\n![img](images/x.png) 说明\n[link](https://a.com)';
      const expected =
          '标题\n![img](${base}images/x.png) 说明\n[link](https://a.com)';
      expect(resolveReadmeImageUrls(input, base), expected);
    });

    test('空 alt 图片也替换', () {
      expect(
        resolveReadmeImageUrls('![](logo.png)', base),
        '![](${base}logo.png)',
      );
    });
  });

  group('isSvgUrl', () {
    test('.svg 后缀 → true', () {
      expect(isSvgUrl('https://x.com/a.svg'), isTrue);
    });

    test('.svg?query 后缀 → true', () {
      expect(isSvgUrl('https://x.com/a.svg?raw=1'), isTrue);
    });

    test('大写 .SVG 后缀 → true（大小写不敏感）', () {
      expect(isSvgUrl('https://x.com/A.SVG'), isTrue);
    });

    test('.png 后缀 → false', () {
      expect(isSvgUrl('https://x.com/a.png'), isFalse);
    });

    test('.svgz 后缀 → false（不误判 .svg 前缀）', () {
      expect(isSvgUrl('https://x.com/a.svgz'), isFalse);
    });
  });
}
