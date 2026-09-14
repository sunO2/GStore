import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/fdroid/FdroidRepoDeepLink.dart';

void main() {
  group('FdroidRepoDeepLink：第三方源深链解析', () {
    test('fdroidrepos:// → https，且提取 fingerprint', () {
      final link = FdroidRepoDeepLink.parse(
        'fdroidrepos://releases.bitwarden.com/fdroid/repo?fingerprint=Ab:Cd:Ef',
      )!;
      expect(link.url, 'https://releases.bitwarden.com/fdroid/repo');
      // 统一大写并去掉冒号，便于与仓库指纹比对
      expect(link.fingerprint, 'ABCDEF');
    });

    test('fdroidrepo:// → http（局域网自建源）', () {
      final link = FdroidRepoDeepLink.parse('fdroidrepo://192.168.1.5:8080/fdroid/repo')!;
      expect(link.url, 'http://192.168.1.5:8080/fdroid/repo');
      expect(link.fingerprint, isNull);
    });

    test('只给域名时保留原样（自动补 /fdroid/repo 由模块负责）', () {
      final link = FdroidRepoDeepLink.parse('example.com')!;
      expect(link.url, 'https://example.com');
    });

    test('去掉尾斜杠与 fragment', () {
      final link = FdroidRepoDeepLink.parse('https://example.com/fdroid/repo/#frag')!;
      expect(link.url, 'https://example.com/fdroid/repo');
    });

    test('空输入 / 无主机返回 null', () {
      expect(FdroidRepoDeepLink.parse('   '), isNull);
      expect(FdroidRepoDeepLink.parse('https://'), isNull);
    });

    test('fingerprint 参数缺失时不影响解析', () {
      final link = FdroidRepoDeepLink.parse('https://example.com/fdroid/repo?other=1')!;
      expect(link.url, 'https://example.com/fdroid/repo');
      expect(link.fingerprint, isNull);
    });
  });
}
