import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';
import 'package:gstore/core/model/AppDetailInfoView.dart';
import 'package:gstore/core/update/app_update_info.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('AppUpdateInfo 缓存 JSON 往返保留 downloads 字段', () {
    final arm = DownloadInfo(
      url: 'https://example.com/app-arm64-v8a-v2.0.0.apk',
      name: 'app-arm64-v8a-v2.0.0.apk',
      size: 987654,
      downloadCount: 12,
      version: '2.0.0',
      versionCode: 200,
      publishedAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
      platform: 'arm64-v8a',
      hash: 'abc123',
      hashType: 'sha256',
      downloadable: false,
      note: '需要凭证',
    );
    final info = AppUpdateInfo(
      channelId: 'github',
      appId: 'com.example.app',
      appName: 'Example App',
      packageName: 'com.example.app',
      installedVersion: '1.0.0',
      latestVersion: '2.0.0',
      latestDownload: arm,
      downloadCandidates: [arm],
      selectionSource: 'preference',
      checkedAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
    );

    final restored = AppUpdateInfo.fromCacheJson(info.toCacheJson());

    expect(restored.detail, isNull);
    expect(restored.selectionSource, 'preference');
    expect(restored.downloads, hasLength(1));
    final d = restored.downloads.first;
    expect(d.name, 'app-arm64-v8a-v2.0.0.apk');
    expect(d.url, 'https://example.com/app-arm64-v8a-v2.0.0.apk');
    expect(d.size, 987654);
    expect(d.version, '2.0.0');
    expect(d.versionCode, 200);
    expect(d.publishedAt?.millisecondsSinceEpoch, 1700000000000);
    expect(d.platform, 'arm64-v8a');
    expect(d.hash, 'abc123');
    expect(d.hashType, 'sha256');
    expect(d.downloadable, isFalse);
    expect(d.note, '需要凭证');
  });

  test('AppUpdateInfo 缓存 JSON 缺少 downloads → 空列表（向后兼容）', () {
    final restored = AppUpdateInfo.fromCacheJson(<String, dynamic>{
      'channelId': 'github',
      'appId': 'com.example.app',
      'appName': 'Example App',
      'packageName': 'com.example.app',
      'installedVersion': '1.0.0',
      'latestVersion': '2.0.0',
      'download': {
        'url': 'https://example.com/app-2.0.0.apk',
        'name': 'app-2.0.0.apk',
      },
    });

    expect(restored.downloads, isEmpty);
    expect(restored.latestDownload.name, 'app-2.0.0.apk');
  });

  test('downloadCandidates 为空时 downloads 回退 detail.downloads', () {
    final arm = DownloadInfo(
      url: 'https://example.com/app-arm64-v8a-v2.0.0.apk',
      name: 'app-arm64-v8a-v2.0.0.apk',
      platform: 'arm64-v8a',
    );
    final detail = AppDetailInfoView(AppDetailInfo(
      appId: 'com.example.app',
      name: 'Example App',
      icon: '',
      description: '描述',
      channel: ChannelType.github,
      sections: const [],
      downloads: [arm],
    ));
    final info = AppUpdateInfo(
      channelId: 'github',
      appId: 'com.example.app',
      appName: 'Example App',
      packageName: 'com.example.app',
      installedVersion: '1.0.0',
      latestVersion: '2.0.0',
      latestDownload: arm,
      detail: detail,
    );

    expect(info.downloadCandidates, isEmpty);
    expect(info.downloads, hasLength(1));
    expect(info.downloads.first.name, 'app-arm64-v8a-v2.0.0.apk');
  });
}
