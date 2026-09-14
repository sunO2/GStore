import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/channel/impl/FdroidChannel.dart';

void main() {
  group('图标路径归一化（真机形态）', () {
    test('库里存的 /repo/repo/… 不会变成 /repo/repo/repo/…（f-droid 源实测）', () {
      const raw = '/repo/repo/com.kgurgul.cpuinfo/en-US/icon_Ua_e7Jopk5.png';
      expect(normalizeRepoAssetPath(raw), 'com.kgurgul.cpuinfo/en-US/icon_Ua_e7Jopk5.png');
      expect(
        joinRepoUrl('https://f-droid.org/repo', normalizeRepoAssetPath(raw)),
        'https://f-droid.org/repo/com.kgurgul.cpuinfo/en-US/icon_Ua_e7Jopk5.png',
      );
      expect(joinRepoUrl('https://f-droid.org/repo', normalizeRepoAssetPath(raw)),
          isNot(contains('/repo/repo/repo/')));
    });

    test('v2 相对路径（Bitwarden 源）→ 源地址 + 相对路径', () {
      expect(
        joinRepoUrl('https://mobileapp.bitwarden.com/fdroid/repo',
            normalizeRepoAssetPath('/com.x8bit.bitwarden/en-US/icon_a=.png')),
        'https://mobileapp.bitwarden.com/fdroid/repo/com.x8bit.bitwarden/en-US/icon_a=.png',
      );
    });

    test('旧形态：/fdroid/repo/icons/x.png 与 /icons/x.png 都归一到 icons/x.png', () {
      expect(normalizeRepoAssetPath('/fdroid/repo/icons/x.png'), 'icons/x.png');
      expect(normalizeRepoAssetPath('/icons/x.png'), 'icons/x.png');
      expect(normalizeRepoAssetPath('x.png'), 'x.png');
    });

    test('已带 scheme 的地址原样返回；带 query 时去 query', () {
      expect(normalizeRepoAssetPath('https://cdn.example.com/x.png'), 'https://cdn.example.com/x.png');
      expect(normalizeRepoAssetPath('/repo/a/b.png?v=2'), 'a/b.png');
    });

    test('拼接不会重复斜杠', () {
      expect(joinRepoUrl('https://f-droid.org/repo/', '/a/b.png'), 'https://f-droid.org/repo/a/b.png');
      expect(joinRepoUrl('https://f-droid.org/repo', ''), 'https://f-droid.org/repo');
    });
  });
  _regressionTests();
}

// ── 回归：本次真机问题的组合（模块输出绝对地址 → 渠道再拼一次） ──

void _regressionTests() {
  test('绝对地址透传：joinRepoUrl 不得二次拼接（真机图标 404 根因）', () {
    const base = 'https://mirrors.tuna.tsinghua.edu.cn/fdroid/repo';
    const abs = 'https://mobileapp.bitwarden.com/fdroid/repo/com.x8bit.bitwarden/en-US/icon_x=.png';
    // 单独调用
    expect(joinRepoUrl(base, abs), abs);
    // 真实链路：normalizeRepoAssetPath 保留绝对地址 → joinRepoUrl 也必须保留
    expect(joinRepoUrl(base, normalizeRepoAssetPath(abs)), abs);
    expect(joinRepoUrl(base, normalizeRepoAssetPath(abs)), isNot(contains('/https://')));
    // 相对路径不受影响
    expect(
      joinRepoUrl(base, normalizeRepoAssetPath('/fdroid/repo/com.x/en-US/icon_a=.png')),
      '$base/com.x/en-US/icon_a=.png',
    );
  });
}
