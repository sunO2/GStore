import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';
import 'package:gstore/core/update/app_update_info.dart';
import 'package:gstore/core/update/update_cache.dart';
import 'package:gstore/core/update/update_log.dart';
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

  test('UpdateCache saveLogs/loadLogs 往返保留级别/文本/时间', () async {
    SharedPreferences.setMockInitialValues({});

    final logs = [
      CheckLogEntry(
        level: CheckLogLevel.info,
        text: '开始检测应用更新...',
        time: DateTime.fromMillisecondsSinceEpoch(1700000000000),
      ),
      CheckLogEntry(
        level: CheckLogLevel.update,
        text: '示例应用：发现更新 2.0.0',
        time: DateTime.fromMillisecondsSinceEpoch(1700000005000),
      ),
    ];
    await UpdateCache.saveLogs(logs);

    final restored = await UpdateCache.loadLogs();
    expect(restored, hasLength(2));
    expect(restored[0].level, CheckLogLevel.info);
    expect(restored[0].text, '开始检测应用更新...');
    expect(restored[0].time.millisecondsSinceEpoch, 1700000000000);
    expect(restored[1].level, CheckLogLevel.update);
    expect(restored[1].text, '示例应用：发现更新 2.0.0');
  });

  test('UpdateCache.loadLogs 无记录/损坏返回空列表', () async {
    SharedPreferences.setMockInitialValues({});

    expect(await UpdateCache.loadLogs(), isEmpty);

    // 损坏数据容错
    SharedPreferences.setMockInitialValues({'update_check_logs_v1': 'not-json'});
    expect(await UpdateCache.loadLogs(), isEmpty);
  });

  group('UpdateCache APK 选择偏好', () {
    const channelId = 'github';
    const appId = 'com.example.app';

    test('未保存 → preferredApkName 返回 null', () async {
      SharedPreferences.setMockInitialValues({});

      expect(await UpdateCache.preferredApkName(channelId, appId), isNull);
    });

    test('savePreferredApk 后命中；不同 appId → null（key 隔离）', () async {
      SharedPreferences.setMockInitialValues({});

      await UpdateCache.savePreferredApk(channelId, appId, 'app-2.0.0.apk');

      expect(
        await UpdateCache.preferredApkName(channelId, appId),
        'app-2.0.0.apk',
      );
      expect(
        await UpdateCache.preferredApkName(channelId, 'com.example.other'),
        isNull,
      );
    });

    test('覆盖保存（同 key 换文件名）→ 返回新值', () async {
      SharedPreferences.setMockInitialValues({});

      await UpdateCache.savePreferredApk(channelId, appId, 'app-2.0.0.apk');
      await UpdateCache.savePreferredApk(channelId, appId, 'app-2.0.1.apk');

      expect(
        await UpdateCache.preferredApkName(channelId, appId),
        'app-2.0.1.apk',
      );
    });

    test('savePreferredApk 空文件名 → 删除该键（命中 null）', () async {
      SharedPreferences.setMockInitialValues({});

      await UpdateCache.savePreferredApk(channelId, appId, 'app-2.0.0.apk');
      await UpdateCache.savePreferredApk(channelId, appId, '');

      expect(await UpdateCache.preferredApkName(channelId, appId), isNull);
    });

    test('clearPreferredApk → null', () async {
      SharedPreferences.setMockInitialValues({});

      await UpdateCache.savePreferredApk(channelId, appId, 'app-2.0.0.apk');
      await UpdateCache.clearPreferredApk(channelId, appId);

      expect(await UpdateCache.preferredApkName(channelId, appId), isNull);
    });

    test('多个应用互不干扰', () async {
      SharedPreferences.setMockInitialValues({});

      await UpdateCache.savePreferredApk('github', 'com.a', 'a-1.0.apk');
      await UpdateCache.savePreferredApk('fdroid', 'com.b', 'b-2.0.apk');
      await UpdateCache.savePreferredApk('github', 'com.b', 'b-3.0.apk');

      expect(
        await UpdateCache.preferredApkName('github', 'com.a'),
        'a-1.0.apk',
      );
      expect(
        await UpdateCache.preferredApkName('fdroid', 'com.b'),
        'b-2.0.apk',
      );
      expect(
        await UpdateCache.preferredApkName('github', 'com.b'),
        'b-3.0.apk',
      );
      expect(await UpdateCache.preferredApkName('fdroid', 'com.a'), isNull);
    });

    test('损坏 JSON（预置非法字符串）→ null 不抛异常', () async {
      SharedPreferences.setMockInitialValues(
        {'update_preferred_apk': 'not-json{'},
      );

      expect(await UpdateCache.preferredApkName(channelId, appId), isNull);
    });
  });
}
