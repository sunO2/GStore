import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/utils/unit.dart';

void main() {
  group('convertHtmlImgsToMarkdown', () {
    test('data-src 懒加载图片优先于占位 src', () {
      final md = convertHtmlImgsToMarkdown(
        '<img src="data:image/gif;base64,R0lGODlhAQABAAAAACw=" '
        'data-src="https://example.com/real.png" alt="示意图">',
      );
      expect(md, contains('https://example.com/real.png'));
      expect(md, isNot(contains('data:image/gif')));
      expect(md, contains('示意图'));
    });

    test('srcset 兜底取第一个地址', () {
      final md = convertHtmlImgsToMarkdown(
        '<img srcset="https://example.com/a.png 1x, https://example.com/b.png 2x">',
      );
      expect(md, contains('https://example.com/a.png'));
    });

    test('width/height 仍编码为 title', () {
      final md = convertHtmlImgsToMarkdown(
        '<img src="https://example.com/a.png" width="200px" height="100" alt="a">',
      );
      expect(md, contains('"200x100"'));
    });

    test('details/summary 转成加粗标题', () {
      final md = convertHtmlImgsToMarkdown(
        '<details><summary>点击展开</summary>\n正文内容\n</details>',
      );
      expect(md, contains('**点击展开**'));
      expect(md, contains('正文内容'));
      expect(md, isNot(contains('<details>')));
      expect(md, isNot(contains('<summary>')));
    });

    test('kbd 转行内代码', () {
      final md = convertHtmlImgsToMarkdown('按 <kbd>Ctrl</kbd> + <kbd>C</kbd>');
      expect(md, '按 `Ctrl` + `C`');
    });

    test('解码常见与数字 HTML 实体', () {
      expect(
        convertHtmlImgsToMarkdown('a&nbsp;b &amp; c &lt;tag&gt; &#x4E2D;&#25991;'),
        'a b & c <tag> 中文',
      );
    });
  });
}
