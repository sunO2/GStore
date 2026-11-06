import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/download/download_url_resolver.dart';

void main() {
  group('resolveDownloadUrl（下载服务入口代理兜底）', () {
    const proxy = 'https://gh-proxy.org';
    const normalizedProxy = 'https://gh-proxy.org/';

    test('GitHub release URL 套代理（代理无尾部斜杠会补齐）', () {
      const url =
          'https://github.com/o/r/releases/download/v1/app-arm64.apk';
      expect(
        resolveDownloadUrl(url, proxy: proxy),
        '$normalizedProxy$url',
      );
    });

    test('raw / api / objects 等 GitHub 域名也套代理', () {
      for (final url in const <String>[
        'https://raw.githubusercontent.com/o/r/main/a.txt',
        'https://api.github.com/repos/o/r/zipball/main',
        'https://codeload.github.com/o/r/zip/main',
        'https://objects.githubusercontent.com/github-production-release-asset/a.apk',
      ]) {
        expect(
          resolveDownloadUrl(url, proxy: proxy),
          '$normalizedProxy$url',
          reason: url,
        );
      }
    });

    test('非 GitHub URL 原样返回', () {
      const url = 'https://example.com/releases/app.apk';
      expect(resolveDownloadUrl(url, proxy: proxy), url);
    });

    test('代理为空时原样返回', () {
      const url = 'https://github.com/o/r/releases/download/v1/app.apk';
      expect(resolveDownloadUrl(url, proxy: ''), url);
    });

    test('关闭自动代理时原样返回（即使代理非空）', () {
      const url = 'https://github.com/o/r/releases/download/v1/app.apk';
      expect(
        resolveDownloadUrl(url, proxy: proxy, autoProxy: false),
        url,
      );
    });

    test('已带代理前缀不会二次拼接', () {
      const url = 'https://gh-proxy.org/https://github.com/o/r/releases/download/v1/app.apk';
      expect(resolveDownloadUrl(url, proxy: proxy), url);
    });

    test('已是 path-only 代理格式也不会二次拼接', () {
      const url =
          'https://gh-proxy.org/o/r/releases/download/v1/app.apk';
      expect(resolveDownloadUrl(url, proxy: proxy), url);
    });
  });
}
