import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/download/model/download_task.dart';
import 'package:gstore/page/download/download_status_utils.dart';

DownloadTask _item(DownloadStatusEnum status, {String fileName = 'app.apk'}) {
  return DownloadTask(
    id: 1,
    appId: 'com.example.app',
    appName: '示例应用',
    version: '1.0.0',
    fileName: fileName,
    url: 'https://example.com/$fileName',
    filePath: '/data/media/0/Download/$fileName',
    total: 1000,
    received: 500,
    status: status,
    speedBps: 0,
    etaSec: null,
    error: null,
    segments: null,
    createdAt: DateTime.now(),
    updatedAt: DateTime.now(),
  );
}

void main() {
  group('matchesFilter', () {
    test('downloading 匹配 DOWNLOAD_LOADING 和 DOWNLOAD_READY', () {
      final loading = _item(DownloadStatusEnum.downloading);
      final ready = _item(DownloadStatusEnum.paused);
      expect(matchesFilter(loading, DownloadFilter.downloading), isTrue);
      expect(matchesFilter(ready, DownloadFilter.downloading), isTrue);
    });

    test('downloading 匹配 DOWNLOAD_QUEUED', () {
      final queued = _item(DownloadStatusEnum.queued);
      expect(matchesFilter(queued, DownloadFilter.downloading), isTrue);
    });

    test('downloading 不匹配 DOWNLOAD_SUCCESS 和 DOWNLOAD_ERROR', () {
      final success = _item(DownloadStatusEnum.completed);
      final error = _item(DownloadStatusEnum.failed);
      expect(matchesFilter(success, DownloadFilter.downloading), isFalse);
      expect(matchesFilter(error, DownloadFilter.downloading), isFalse);
    });

    test('completed 仅匹配 DOWNLOAD_SUCCESS', () {
      final success = _item(DownloadStatusEnum.completed);
      final loading = _item(DownloadStatusEnum.downloading);
      final ready = _item(DownloadStatusEnum.paused);
      final error = _item(DownloadStatusEnum.failed);
      expect(matchesFilter(success, DownloadFilter.completed), isTrue);
      expect(matchesFilter(loading, DownloadFilter.completed), isFalse);
      expect(matchesFilter(ready, DownloadFilter.completed), isFalse);
      expect(matchesFilter(error, DownloadFilter.completed), isFalse);
    });

    test('failed 仅匹配 DOWNLOAD_ERROR，READY 必须排除（回归 bug）', () {
      final error = _item(DownloadStatusEnum.failed);
      final ready = _item(DownloadStatusEnum.paused);
      final loading = _item(DownloadStatusEnum.downloading);
      final success = _item(DownloadStatusEnum.completed);
      expect(matchesFilter(error, DownloadFilter.failed), isTrue);
      expect(matchesFilter(ready, DownloadFilter.failed), isFalse);
      expect(matchesFilter(loading, DownloadFilter.failed), isFalse);
      expect(matchesFilter(success, DownloadFilter.failed), isFalse);
    });

    test('all 匹配所有状态', () {
      final loading = _item(DownloadStatusEnum.downloading);
      final ready = _item(DownloadStatusEnum.paused);
      final success = _item(DownloadStatusEnum.completed);
      final error = _item(DownloadStatusEnum.failed);
      final queued = _item(DownloadStatusEnum.queued);
      expect(matchesFilter(loading, DownloadFilter.all), isTrue);
      expect(matchesFilter(ready, DownloadFilter.all), isTrue);
      expect(matchesFilter(success, DownloadFilter.all), isTrue);
      expect(matchesFilter(error, DownloadFilter.all), isTrue);
      expect(matchesFilter(queued, DownloadFilter.all), isTrue);
    });

    test('completed 不匹配 DOWNLOAD_QUEUED', () {
      final queued = _item(DownloadStatusEnum.queued);
      expect(matchesFilter(queued, DownloadFilter.completed), isFalse);
    });

    test('failed 不匹配 DOWNLOAD_QUEUED', () {
      final queued = _item(DownloadStatusEnum.queued);
      expect(matchesFilter(queued, DownloadFilter.failed), isFalse);
    });
  });

  group('statusKindOf', () {
    test('四状态映射', () {
      final loading = _item(DownloadStatusEnum.downloading);
      final ready = _item(DownloadStatusEnum.paused);
      final success = _item(DownloadStatusEnum.completed);
      final error = _item(DownloadStatusEnum.failed);
      expect(statusKindOf(loading), DownloadStatusKind.downloading);
      expect(statusKindOf(ready), DownloadStatusKind.waiting);
      expect(statusKindOf(success), DownloadStatusKind.completed);
      expect(statusKindOf(error), DownloadStatusKind.failed);
    });

    test('DOWNLOAD_QUEUED 映射到 queued', () {
      final queued = _item(DownloadStatusEnum.queued);
      expect(statusKindOf(queued), DownloadStatusKind.queued);
    });
  });

  group('primaryActionFor', () {
    test('LOADING → pause', () {
      final loading = _item(DownloadStatusEnum.downloading);
      expect(primaryActionFor(loading), DownloadAction.pause);
    });

    test('READY → resume', () {
      final ready = _item(DownloadStatusEnum.paused);
      expect(primaryActionFor(ready), DownloadAction.resume);
    });

    test('ERROR → retry', () {
      final error = _item(DownloadStatusEnum.failed);
      expect(primaryActionFor(error), DownloadAction.retry);
    });

    test('SUCCESS 且 .apk 结尾 → install', () {
      final successApk = _item(DownloadStatusEnum.completed);
      expect(primaryActionFor(successApk), DownloadAction.install);
    });

    test('SUCCESS 且非 .apk 结尾 → null', () {
      final successPdf = _item(
        DownloadStatusEnum.completed,
        fileName: 'manual.pdf',
      );
      expect(primaryActionFor(successPdf), isNull);
    });

    test('DOWNLOAD_QUEUED → cancel', () {
      final queued = _item(DownloadStatusEnum.queued);
      expect(primaryActionFor(queued), DownloadAction.cancel);
    });
  });

  group('inferChannelLabel', () {
    test('GitHub API 链接 → GitHub', () {
      expect(
        inferChannelLabel(
            'https://api.github.com/repos/gkd-kit/gkd/releases/download/v1.0/gkd.apk'),
        'GitHub',
      );
    });

    test('GitHub raw 链接 → GitHub', () {
      expect(
        inferChannelLabel(
            'https://raw.githubusercontent.com/sunO2/GStore-Repositorys/main/README.md'),
        'GitHub',
      );
    });

    test('带代理前缀的 GitHub 链接仍识别为 GitHub（内含 github.com）', () {
      expect(
        inferChannelLabel(
            'https://ghfast.top/https://github.com/sunO2/GStore/releases/download/v1/app.apk'),
        'GitHub',
      );
    });

    test('vivo 域名 → vivo 应用市场', () {
      expect(
        inferChannelLabel(
            'https://app.vss.cn/pp/xx.apk'),
        'vivo 应用市场',
      );
    });

    test('未知域名 → null', () {
      expect(inferChannelLabel('https://example.com/app.apk'), isNull);
    });

    test('空链接 → null', () {
      expect(inferChannelLabel(''), isNull);
    });
  });

  group('formatSpeed', () {
    test('零速度返回空字符串', () {
      expect(formatSpeed(0), '');
    });

    test('负值返回空字符串', () {
      expect(formatSpeed(-100), '');
    });

    test('B/s 范围 (0 < x < 1024)', () {
      expect(formatSpeed(512), '512 B/s');
      expect(formatSpeed(1), '1 B/s');
      expect(formatSpeed(1023), '1023 B/s');
    });

    test('KB/s 范围 (1024 <= x < 1048576)', () {
      expect(formatSpeed(1024), '1 KB/s');
      expect(formatSpeed(856 * 1024), '856 KB/s');
      expect(formatSpeed(1024 * 1024 - 1), '1024 KB/s');
    });

    test('MB/s 范围 (x >= 1048576)', () {
      expect(formatSpeed(10 * 1024 * 1024), '10.0 MB/s');
      expect(formatSpeed(12.5 * 1024 * 1024), '12.5 MB/s');
      expect(formatSpeed(1024 * 1024), '1.0 MB/s');
    });
  });

  group('formatDuration', () {
    test('零秒返回空字符串', () {
      expect(formatDuration(0), '');
    });

    test('负秒返回空字符串', () {
      expect(formatDuration(-5), '');
    });

    test('秒级 (< 60s)', () {
      expect(formatDuration(1), '剩余 1s');
      expect(formatDuration(30), '剩余 30s');
      expect(formatDuration(59), '剩余 59s');
    });

    test('分钟级 (60s <= x < 3600s)', () {
      expect(formatDuration(60), '剩余 1m');
      expect(formatDuration(135), '剩余 2m 15s');
      expect(formatDuration(300), '剩余 5m');
    });

    test('小时级 (x >= 3600s)', () {
      expect(formatDuration(3600), '剩余 1h');
      expect(formatDuration(3660), '剩余 1h 1m');
      expect(formatDuration(7200), '剩余 2h');
      expect(formatDuration(5400), '剩余 1h 30m');
    });
  });
}
