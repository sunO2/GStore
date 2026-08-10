import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/utils/unit.dart';

void main() {
  group('byteSize', () {
    test('B 单位（小于 1KB）', () {
      expect(byteSize(0), '0 B');
      expect(byteSize(1), '1 B');
      expect(byteSize(1023), '1023 B');
    });

    test('KB 单位', () {
      expect(byteSize(1024), '1.00 KB');
      expect(byteSize(2048), '2.00 KB');
      expect(byteSize(1536), '1.50 KB');
    });

    test('MB 单位', () {
      expect(byteSize(1024 * 1024), '1.00 MB');
      expect(byteSize(5 * 1024 * 1024), '5.00 MB');
      expect(byteSize(1536 * 1024), '1.50 MB');
    });

    test('GB 单位', () {
      expect(byteSize(1024 * 1024 * 1024), '1.00 GB');
      expect(byteSize(2 * 1024 * 1024 * 1024), '2.00 GB');
      expect(byteSize(1536 * 1024 * 1024), '1.50 GB');
    });

    test('边界值', () {
      expect(byteSize(1023), '1023 B');
      expect(byteSize(1024), '1.00 KB');
      expect(byteSize(1024 * 1024 - 1), '1024.00 KB');
      expect(byteSize(1024 * 1024), '1.00 MB');
    });
  });

  group('isGithubUrl', () {
    test('github.com 主域名', () {
      expect(isGithubUrl('https://github.com/termux/termux-app'), true);
      expect(isGithubUrl('http://github.com/foo/bar'), true);
    });

    test('githubusercontent 相关域名', () {
      expect(isGithubUrl('https://raw.githubusercontent.com/a/b/main/x'), true);
      expect(isGithubUrl('https://api.github.com/repos/a/b'), true);
      expect(isGithubUrl('https://objects.githubusercontent.com/x'), true);
      expect(isGithubUrl('https://user-images.githubusercontent.com/x.png'), true);
      expect(isGithubUrl('https://avatars.githubusercontent.com/u/1'), true);
      expect(isGithubUrl('https://camo.githubusercontent.com/x'), true);
    });

    test('非 GitHub 域名', () {
      expect(isGithubUrl('https://example.com/foo'), false);
      expect(isGithubUrl('https://gitlab.com/foo/bar'), false);
      expect(isGithubUrl('https://play.google.com/store'), false);
      expect(isGithubUrl(''), false);
    });
  });

  group('applyProxyIfNeeded', () {
    test('未配置代理时原样返回', () {
      expect(applyProxyIfNeeded('https://github.com/a/b', ''), 'https://github.com/a/b');
    });

    test('非 GitHub URL 不套代理', () {
      expect(
        applyProxyIfNeeded('https://example.com/x', 'https://proxy.example.com/'),
        'https://example.com/x',
      );
    });

    test('GitHub URL 添加代理前缀', () {
      expect(
        applyProxyIfNeeded(
          'https://github.com/termux/termux-app',
          'https://gh-proxy.example.com/',
        ),
        'https://gh-proxy.example.com/https://github.com/termux/termux-app',
      );
    });

    test('已带代理前缀不重复添加', () {
      expect(
        applyProxyIfNeeded(
          'https://gh-proxy.example.com/https://github.com/a/b',
          'https://gh-proxy.example.com/',
        ),
        'https://gh-proxy.example.com/https://github.com/a/b',
      );
    });

    test('raw.githubusercontent 走代理', () {
      expect(
        applyProxyIfNeeded(
          'https://raw.githubusercontent.com/a/b/main/x.apk',
          'https://gh-proxy.example.com/',
        ),
        'https://gh-proxy.example.com/https://raw.githubusercontent.com/a/b/main/x.apk',
      );
    });
  });

  group('compareVersion 边界补充', () {
    test('相同版本', () {
      expect(compareVersion('1.2.3', '1.2.3'), 0);
    });

    test('新版本更大', () {
      expect(compareVersion('1.2.3', '1.2.4'), 1);
      expect(compareVersion('1.2.3', '1.3.0'), 1);
      expect(compareVersion('1.9', '2.0'), 1);
    });

    test('旧版本更大', () {
      expect(compareVersion('2.0.0', '1.9.9'), -1);
    });

    test('位数不足补零比较', () {
      expect(compareVersion('1.2', '1.2.0'), 0);
      expect(compareVersion('1.2.0', '1.2.0.1'), 1);
      expect(compareVersion('1.2.0.1', '1.2.0'), -1);
    });

    test('非数字版本视为 0', () {
      expect(compareVersion('abc', '1.0.0'), 1);
      expect(compareVersion('abc', 'def'), 0);
    });

    test('后缀版本（数字相同视为相等）', () {
      expect(compareVersion('1.0.0-beta', '1.0.0'), 0);
      expect(compareVersion('1.0.0', '1.0.1-beta'), 1);
    });
  });
}
