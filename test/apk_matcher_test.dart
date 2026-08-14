import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';
import 'package:gstore/core/update/apk_matcher.dart';

DownloadInfo _dl(String name) => DownloadInfo(url: 'https://example.com/$name', name: name);

void main() {
  group('pickClosestApk', () {
    test('空候选 → null', () {
      expect(pickClosestApk(const [], 'app.apk'), isNull);
    });

    test('preferred 为空 → null', () {
      expect(pickClosestApk([_dl('app.apk')], ''), isNull);
      expect(pickClosestApk([_dl('app.apk')], '  '), isNull);
    });

    test('完全一致 → 该项（距离 0）', () {
      final target = _dl('app-arm64-v8a-v1.0.apk');
      final result = pickClosestApk([_dl('app-x86_64-v1.0.apk'), target], 'app-arm64-v8a-v1.0.apk');
      expect(result, same(target));
    });

    test('版本变化：同架构取距离更小的候选', () {
      final old = _dl('app-x86_64-v1.1.apk');
      final arm = _dl('app-arm64-v8a-v1.1.apk');
      final result = pickClosestApk([old, arm], 'app-arm64-v8a-v1.0.apk');
      expect(result, same(arm));
    });

    test('大小写不敏感：APP.APK 命中 app.apk', () {
      final target = _dl('app.apk');
      final result = pickClosestApk([target], 'APP.APK');
      expect(result, same(target));
    });

    test('universal：距离 0 优先于其他候选', () {
      final base = _dl('app.apk');
      final v2 = _dl('app-2.0.apk');
      final result = pickClosestApk([base, v2], 'app.apk');
      expect(result, same(base));
    });

    test('同距离靠前：列表顺序决定', () {
      final first = _dl('abd.apk');
      final second = _dl('abe.apk');
      final result = pickClosestApk([first, second], 'abc.apk');
      expect(result, same(first));
    });

    test('架构消失回退：唯一候选被选中', () {
      final fallback = _dl('app.apk');
      final result = pickClosestApk([fallback], 'app-arm64.apk');
      expect(result, same(fallback));
    });

    test('单候选直接返回', () {
      final only = _dl('whatever-1.2.3.apk');
      final result = pickClosestApk([only], 'something-else.apk');
      expect(result, same(only));
    });
  });

  group('isInstallableDownload', () {
    test('.apk / .aab 为真（大小写不敏感）', () {
      expect(isInstallableDownload(_dl('app.apk')), isTrue);
      expect(isInstallableDownload(_dl('app.aab')), isTrue);
      expect(isInstallableDownload(_dl('app.APK')), isTrue);
      expect(isInstallableDownload(_dl('app-arm64-v8a-v2.0.0.apk')), isTrue);
      expect(isInstallableDownload(_dl('App-Release.AAB')), isTrue);
    });

    test('非 .apk/.aab 为假（zip/txt/md/无扩展名）', () {
      expect(isInstallableDownload(_dl('app.zip')), isFalse);
      expect(isInstallableDownload(_dl('app.txt')), isFalse);
      expect(isInstallableDownload(_dl('README.md')), isFalse);
      expect(isInstallableDownload(_dl('app')), isFalse);
      expect(isInstallableDownload(_dl('app.apk.zip')), isFalse);
    });
  });

  group('filterInstallableDownloads', () {
    test('仅保留 .apk/.aab（大小写不敏感），剔除 zip/txt/md/无扩展名', () {
      final downloads = [
        _dl('app-arm64-v8a-v2.0.0.apk'),
        _dl('app-arm64-v8a-v2.0.0.zip'),
        _dl('notes.txt'),
        _dl('README.md'),
        _dl('app-universal-v2.0.0.APK'),
        _dl('bundle-v2.0.0.aab'),
        _dl('noext'),
      ];
      final result = filterInstallableDownloads(downloads);
      expect(
        result.map((e) => e.name).toList(),
        ['app-arm64-v8a-v2.0.0.apk', 'app-universal-v2.0.0.APK', 'bundle-v2.0.0.aab'],
      );
    });

    test('空列表 → 空列表（不抛错）', () {
      expect(filterInstallableDownloads(const []), isEmpty);
    });

    test('全部可安装 → 原样返回（顺序保留）', () {
      final downloads = [_dl('a.apk'), _dl('b.aab'), _dl('c.apk')];
      final result = filterInstallableDownloads(downloads);
      expect(result.map((e) => e.name).toList(),
          downloads.map((e) => e.name).toList());
    });
  });

  group('selectDownloadWithPreference', () {
    final fallback = _dl('app-universal-v2.0.0.apk');
    final arm = _dl('app-arm64-v8a-v2.0.0.apk');
    final x86 = _dl('app-x86_64-v2.0.0.apk');
    final candidates = [fallback, arm, x86];

    test('偏好匹配候选（非渠道默认首项）→ 返回匹配项', () {
      final result = selectDownloadWithPreference(
        fallback: fallback,
        candidates: candidates,
        preferred: 'app-arm64-v8a-v2.0.0.apk',
      );
      expect(result, same(arm));
    });

    test('偏好无精确匹配：最近候选即默认首项 → 结果与 fallback 相同（现规则不变）', () {
      // pickClosestApk 在候选非空时始终返回最近者；当最近者恰为默认项
      // （如旧版本 universal 偏好）时，选择结果与现规则 latestDownload 一致
      final result = selectDownloadWithPreference(
        fallback: fallback,
        candidates: candidates,
        preferred: 'app-universal-v2.1.0.apk',
      );
      expect(result, same(fallback));
    });

    test('无偏好（null / 空串）→ fallback（现规则）', () {
      expect(
        selectDownloadWithPreference(fallback: fallback, candidates: candidates, preferred: null),
        same(fallback),
      );
      expect(
        selectDownloadWithPreference(fallback: fallback, candidates: candidates, preferred: ''),
        same(fallback),
      );
      expect(
        selectDownloadWithPreference(fallback: fallback, candidates: candidates, preferred: '  '),
        same(fallback),
      );
    });

    test('candidates 为 null（缓存恢复 detail 为空）→ 回退 fallback', () {
      final result = selectDownloadWithPreference(
        fallback: fallback,
        candidates: null,
        preferred: 'app-arm64-v8a-v2.0.0.apk',
      );
      expect(result, same(fallback));
    });

    test('candidates 空列表 → 回退 fallback', () {
      final result = selectDownloadWithPreference(
        fallback: fallback,
        candidates: const [],
        preferred: 'app-arm64-v8a-v2.0.0.apk',
      );
      expect(result, same(fallback));
    });

    test('完全一致（距离 0）→ 直选', () {
      final result = selectDownloadWithPreference(
        fallback: fallback,
        candidates: candidates,
        preferred: 'app-x86_64-v2.0.0.apk',
      );
      expect(result, same(x86));
    });
  });
}
