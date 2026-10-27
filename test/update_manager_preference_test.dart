/// UpdateManager APK 选择偏好测试。
///
/// 增量 1 删除了 Dart 旧检测引擎（`_checkOneApp` / 公开入口 `checkApp`）。
/// 本文件原先通过真实 `UpdateManagerService.checkApp` 走"偏好读取 → 候选
/// 相似度匹配 → `latestDownload` 落值"的全链路冒烟，该链路随引擎一并删除，
/// 已无生产代码可测，故原测试全部移除。
///
/// 仍然存活的覆盖：
/// - 选择逻辑四象限（匹配/不匹配/无偏好/detail 为空）由
///   `apk_matcher_test.dart` 的 `selectDownloadWithPreference` 单测覆盖；
/// - 偏好持久化（`savePreferredApk` / `preferredApkName` / `clearPreferredApk`，
///   更新页仍在用）由 `update_cache_test.dart` 的「APK 选择偏好」分组覆盖，
///   这里再做一个引擎删除后的存活冒烟。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/update/update_cache.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  test('偏好持久化：savePreferredApk 命中，clearPreferredApk 后返回 null', () async {
    const channelId = 'github';
    const appId = 'com.example.app';

    await UpdateCache.savePreferredApk(channelId, appId, 'app-arm64-v8a.apk');
    expect(
      await UpdateCache.preferredApkName(channelId, appId),
      'app-arm64-v8a.apk',
    );

    await UpdateCache.clearPreferredApk(channelId, appId);
    expect(await UpdateCache.preferredApkName(channelId, appId), isNull);
  });
}
