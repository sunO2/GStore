import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';
import 'package:gstore/core/update/app_update_info.dart';
import 'package:gstore/core/update/update_cache.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('UpdateCache saveResults/loadResults 往返保留字段', () async {
    SharedPreferences.setMockInitialValues({});

    final info = AppUpdateInfo(
      channelId: 'github',
      appId: 'com.example.app',
      appName: 'Example App',
      packageName: 'com.example.app',
      installedVersion: '1.0.0',
      latestVersion: '2.0.0',
      latestDownload: DownloadInfo(
        url: 'https://example.com/app-2.0.0.apk',
        name: 'app-2.0.0.apk',
        size: 12345678,
        version: '2.0.0',
      ),
      // detail 不持久化：恢复后为 null，下载降级普通下载
      detail: null,
      checkedAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
    );

    await UpdateCache.saveResults([info]);

    // 模拟应用重启：重置静态单例（不清空底层存储），跨实例读取
    SharedPreferences.resetStatic();

    final loaded = await UpdateCache.loadResults();
    expect(loaded, hasLength(1));

    final restored = loaded.first;
    expect(restored.appId, 'com.example.app');
    expect(restored.appName, 'Example App');
    expect(restored.installedVersion, '1.0.0');
    expect(restored.latestVersion, '2.0.0');
    expect(restored.latestDownload.url, 'https://example.com/app-2.0.0.apk');
    expect(restored.latestDownload.size, 12345678);
    expect(restored.detail, isNull);
  });

  test('UpdateCache.loadResults 无记录返回空列表', () async {
    SharedPreferences.setMockInitialValues({});

    final loaded = await UpdateCache.loadResults();
    expect(loaded, isEmpty);
  });
}
