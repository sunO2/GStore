import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/fdroid/FdroidRepoModels.dart';
import 'package:gstore/core/rust/FdroidRustRepoManager.dart';

void main() {
  group('源身份与数据槽隔离', () {
    test('有指纹时以指纹为身份（去冒号、忽略大小写）', () {
      final a = FdroidRustRepoManager.sourceIdentity(
          fingerprint: 'ab:cd:ef', repoUrl: 'https://a.example/fdroid/repo');
      final b = FdroidRustRepoManager.sourceIdentity(
          fingerprint: 'ABCDEF', repoUrl: 'https://完全不同.example/x');
      expect(a, b, reason: '仓库身份是签名密钥，地址不同也应视为同一个源');
      expect(a, 'fp:ABCDEF');
    });

    test('无指纹时回退到归一化地址（去尾斜杠 + 小写 scheme/host）', () {
      final a = FdroidRustRepoManager.sourceIdentity(repoUrl: 'HTTPS://Example.COM/fdroid/repo/');
      final b = FdroidRustRepoManager.sourceIdentity(repoUrl: 'https://example.com/fdroid/repo');
      expect(a, b);
      expect(a, 'url:https://example.com/fdroid/repo');
    });

    test('路径大小写不折叠（只归一 scheme 与 host）', () {
      expect(FdroidRustRepoManager.normalizeRepoUrl('https://e.com/Repo'),
          'https://e.com/Repo');
    });

    test('不同源 → 不同的库文件；同一个源 → 稳定同名', () {
      final p1 = FdroidRustRepoManager.dbPathForIdentity('fp:AA', '/docs');
      final p2 = FdroidRustRepoManager.dbPathForIdentity('fp:AB', '/docs');
      final p1again = FdroidRustRepoManager.dbPathForIdentity('fp:AA', '/docs');
      expect(p1, p1again, reason: '同一身份必须稳定');
      expect(p1, isNot(p2), reason: '不同源不能共用数据槽');
      expect(p1, startsWith('/docs/fdroid_'));
      expect(p1, endsWith('.db'));
    });

    test('sourceIdentity 是**逻辑**身份，不作存储槽位：槽位恒为 storageIdentity（源 id）', () {
      final fresh = FdroidSource(
        id: 'official',
        name: 'F-Droid Official',
        repoUrl: 'https://f-droid.org/repo',
      );
      final backfilled = fresh.copyWith(fingerprint: 'AB:CD');

      // 逻辑身份（用于同源判定）：指纹优先 → 指纹回填前后会变化
      expect(
        FdroidRustRepoManager.sourceIdentity(
            fingerprint: fresh.fingerprint, repoUrl: fresh.repoUrl),
        'url:https://f-droid.org/repo',
      );
      expect(
        FdroidRustRepoManager.sourceIdentity(
            fingerprint: backfilled.fingerprint, repoUrl: backfilled.repoUrl),
        'fp:ABCD',
      );

      // 存储槽位（用于实例键 / 库文件）：指纹回填前后**恒定**
      expect(FdroidRustRepoManager.storageIdentity(fresh), 'official');
      expect(FdroidRustRepoManager.storageIdentity(backfilled), 'official');
      expect(
        FdroidRustRepoManager.dbPathForIdentity(
            FdroidRustRepoManager.storageIdentity(fresh), '/docs'),
        FdroidRustRepoManager.dbPathForIdentity(
            FdroidRustRepoManager.storageIdentity(backfilled), '/docs'),
        reason: '指纹发现不得改变库槽位（否则首次加载中途翻槽）',
      );
    });
  });
}
