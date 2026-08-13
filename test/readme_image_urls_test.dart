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

    test('HTML img src 相对路径拼接 base', () {
      expect(
        resolveReadmeImageUrls('<img src="screenshots/x.png">', base),
        '<img src="${base}screenshots/x.png">',
      );
    });

    test('a 标签内 HTML img 仅替换内层 src，a 标签与 alt 保留', () {
      expect(
        resolveReadmeImageUrls(
          '<a href="https://x"><img src="screenshots/unnamed.jpg" alt="y" /></a>',
          base,
        ),
        '<a href="https://x"><img src="${base}screenshots/unnamed.jpg" alt="y" /></a>',
      );
    });

    test('HTML img 绝对 URL 不动', () {
      const src = '<img src="https://example.com/x.png">';
      expect(resolveReadmeImageUrls(src, base), src);
    });

    test('HTML img 和 Markdown 图片混合都替换', () {
      expect(
        resolveReadmeImageUrls(
          '<img src="screenshots/a.png">\n![b](img/b.png)',
          base,
        ),
        '<img src="${base}screenshots/a.png">\n![b](${base}img/b.png)',
      );
    });
  });

  group('convertHtmlImgsToMarkdown', () {
    test('无 alt 无尺寸 → ![](URL)', () {
      expect(
        convertHtmlImgsToMarkdown('<img src="https://a.com/x.png">'),
        '![](https://a.com/x.png)',
      );
    });

    test('带 alt → ![alt](URL)', () {
      expect(
        convertHtmlImgsToMarkdown('<img src="https://a.com/x.png" alt="logo">'),
        '![logo](https://a.com/x.png)',
      );
    });

    test('alt + width/height → ![alt](URL "WxH")', () {
      expect(
        convertHtmlImgsToMarkdown(
          '<img src="https://a.com/x.png" alt="logo" width="200" height="100">',
        ),
        '![logo](https://a.com/x.png "200x100")',
      );
    });

    test('width/height 带 px 后缀 → 剥离 px 编码 "WxH"', () {
      expect(
        convertHtmlImgsToMarkdown(
          '<img src="https://a.com/x.png" alt="logo" width="200px" height="100px">',
        ),
        '![logo](https://a.com/x.png "200x100")',
      );
    });

    test('width 含 % → 不编码 title，仅保留 alt', () {
      expect(
        convertHtmlImgsToMarkdown(
          '<img src="https://a.com/x.png" alt="logo" width="50%">',
        ),
        '![logo](https://a.com/x.png)',
      );
    });

    test('仅 width → title "Wx"（高度由 _ReadmeImage loose 自适应）', () {
      expect(
        convertHtmlImgsToMarkdown(
          '<img src="https://a.com/x.png" alt="logo" width="150px">',
        ),
        '![logo](https://a.com/x.png "150x")',
      );
    });

    test('仅 height → title "xH"（宽度等比补全）', () {
      expect(
        convertHtmlImgsToMarkdown(
          '<img src="https://a.com/x.png" alt="logo" height="100">',
        ),
        '![logo](https://a.com/x.png "x100")',
      );
    });

    test('自闭合 <img src="x.png" /> → ![](x.png)', () {
      expect(
        convertHtmlImgsToMarkdown('<img src="x.png" />'),
        '![](x.png)',
      );
    });

    test('多 img 混合文本 → 都转换、文字保留', () {
      const input =
          '标题段落\n<img src="a.png" alt="一">\n中间文字\n<img src="b.png" alt="二" width="10" height="20">\n结尾';
      const expected =
          '标题段落\n![一](a.png)\n中间文字\n![二](b.png "10x20")\n结尾';
      expect(convertHtmlImgsToMarkdown(input), expected);
    });

    test('无 src 的 img → 原样保留', () {
      const input = '<img alt="logo" width="100">';
      expect(convertHtmlImgsToMarkdown(input), input);
    });

    test('非 img HTML（<br>/<div>/<a>）→ 原样不动', () {
      const input = '<br>\n<div>text</div>\n<a href="https://a.com">link</a>';
      expect(convertHtmlImgsToMarkdown(input), input);
    });

    test('img 与文本相邻（无换行）→ 不吞文本', () {
      expect(
        convertHtmlImgsToMarkdown('前置<img src="a.png">后置'),
        '前置![](a.png)后置',
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

    test('shields.io 无后缀动态徽章 → true', () {
      expect(
        isSvgUrl(
          'https://img.shields.io/badge/App_Store-Download-0D96F6?logo=apple&logoColor=white',
        ),
        isTrue,
      );
    });

    test('shields.io 带 .svg 后缀 URL → true', () {
      expect(isSvgUrl('https://img.shields.io/pub/v/x.svg'), isTrue);
    });

    test('普通 .png URL → false', () {
      expect(isSvgUrl('https://example.com/a.png'), isFalse);
    });

    test('无扩展名非 shields.io URL → false', () {
      expect(isSvgUrl('https://example.com/badge/foo'), isFalse);
    });
  });
}
