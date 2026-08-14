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
}
