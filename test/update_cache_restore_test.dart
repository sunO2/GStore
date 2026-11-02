import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';
import 'package:gstore/core/update/app_update_info.dart';
import 'package:gstore/core/update/update_log.dart';
import 'package:gstore/core/update/update_manager.dart';

AppUpdateInfo _cachedInfo() => AppUpdateInfo(
      channelId: 'github',
      appId: 'owner/app',
      appName: 'Cached App',
      packageName: 'com.example.cached',
      installedVersion: '1.0.0',
      latestVersion: '2.0.0',
      latestDownload: DownloadInfo(
        url: 'https://example.test/app.apk',
        name: 'app.apk',
        size: 10,
        version: '2.0.0',
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('启动时从 Rust 核心缓存恢复上次结果/日志/时间', () async {
    final manager = UpdateManagerService();
    final checkedAt = DateTime.fromMillisecondsSinceEpoch(1710000000000);
    manager.cachedStateLoader = () async => (
          updates: [_cachedInfo()],
          logs: [
            CheckLogEntry(
              level: CheckLogLevel.update,
              text: 'Cached App：发现更新 1.0.0 → 2.0.0',
              time: checkedAt,
            ),
          ],
          lastCheckedAt: checkedAt,
        );

    await manager.cacheRestored;

    expect(manager.updateList.single.appId, 'owner/app');
    expect(manager.checkLog.single.text, contains('发现更新'));
    expect(manager.lastCheckedAt, checkedAt);
  });
}
