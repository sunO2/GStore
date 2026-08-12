import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/http/download/DownloadStatus.dart';
import 'package:gstore/page/download/download_status_utils.dart';

DownloadStatus _item(int status, {String fileName = 'app.apk'}) {
  // status 是可变字段，构造后赋值，规避构造器将 LOADING 重置为 READY 的行为
  final item = DownloadStatus(
    'com.example.app',
    '示例应用',
    '1.0.0',
    fileName,
    'https://example.com/$fileName',
    '/data/media/0/Download/$fileName',
  );
  item.status = status;
  return item;
}

void main() {
  group('matchesFilter', () {
    test('downloading 匹配 DOWNLOAD_LOADING 和 DOWNLOAD_READY', () {
      final loading = _item(DownloadStatus.DOWNLOAD_LOADING);
      final ready = _item(DownloadStatus.DOWNLOAD_READY);
      expect(matchesFilter(loading, DownloadFilter.downloading), isTrue);
      expect(matchesFilter(ready, DownloadFilter.downloading), isTrue);
    });

    test('downloading 不匹配 DOWNLOAD_SUCCESS 和 DOWNLOAD_ERROR', () {
      final success = _item(DownloadStatus.DOWNLOAD_SUCCESS);
      final error = _item(DownloadStatus.DOWNLOAD_ERROR);
      expect(matchesFilter(success, DownloadFilter.downloading), isFalse);
      expect(matchesFilter(error, DownloadFilter.downloading), isFalse);
    });

    test('completed 仅匹配 DOWNLOAD_SUCCESS', () {
      final success = _item(DownloadStatus.DOWNLOAD_SUCCESS);
      final loading = _item(DownloadStatus.DOWNLOAD_LOADING);
      final ready = _item(DownloadStatus.DOWNLOAD_READY);
      final error = _item(DownloadStatus.DOWNLOAD_ERROR);
      expect(matchesFilter(success, DownloadFilter.completed), isTrue);
      expect(matchesFilter(loading, DownloadFilter.completed), isFalse);
      expect(matchesFilter(ready, DownloadFilter.completed), isFalse);
      expect(matchesFilter(error, DownloadFilter.completed), isFalse);
    });

    test('failed 仅匹配 DOWNLOAD_ERROR，READY 必须排除（回归 bug）', () {
      final error = _item(DownloadStatus.DOWNLOAD_ERROR);
      final ready = _item(DownloadStatus.DOWNLOAD_READY);
      final loading = _item(DownloadStatus.DOWNLOAD_LOADING);
      final success = _item(DownloadStatus.DOWNLOAD_SUCCESS);
      expect(matchesFilter(error, DownloadFilter.failed), isTrue);
      expect(matchesFilter(ready, DownloadFilter.failed), isFalse);
      expect(matchesFilter(loading, DownloadFilter.failed), isFalse);
      expect(matchesFilter(success, DownloadFilter.failed), isFalse);
    });

    test('all 匹配所有状态', () {
      final loading = _item(DownloadStatus.DOWNLOAD_LOADING);
      final ready = _item(DownloadStatus.DOWNLOAD_READY);
      final success = _item(DownloadStatus.DOWNLOAD_SUCCESS);
      final error = _item(DownloadStatus.DOWNLOAD_ERROR);
      expect(matchesFilter(loading, DownloadFilter.all), isTrue);
      expect(matchesFilter(ready, DownloadFilter.all), isTrue);
      expect(matchesFilter(success, DownloadFilter.all), isTrue);
      expect(matchesFilter(error, DownloadFilter.all), isTrue);
    });
  });

  group('statusKindOf', () {
    test('四状态映射', () {
      final loading = _item(DownloadStatus.DOWNLOAD_LOADING);
      final ready = _item(DownloadStatus.DOWNLOAD_READY);
      final success = _item(DownloadStatus.DOWNLOAD_SUCCESS);
      final error = _item(DownloadStatus.DOWNLOAD_ERROR);
      expect(statusKindOf(loading), DownloadStatusKind.downloading);
      expect(statusKindOf(ready), DownloadStatusKind.waiting);
      expect(statusKindOf(success), DownloadStatusKind.completed);
      expect(statusKindOf(error), DownloadStatusKind.failed);
    });
  });

  group('primaryActionFor', () {
    test('LOADING → pause', () {
      final loading = _item(DownloadStatus.DOWNLOAD_LOADING);
      expect(primaryActionFor(loading), DownloadAction.pause);
    });

    test('READY → resume', () {
      final ready = _item(DownloadStatus.DOWNLOAD_READY);
      expect(primaryActionFor(ready), DownloadAction.resume);
    });

    test('ERROR → retry', () {
      final error = _item(DownloadStatus.DOWNLOAD_ERROR);
      expect(primaryActionFor(error), DownloadAction.retry);
    });

    test('SUCCESS 且 .apk 结尾 → install', () {
      final successApk = _item(DownloadStatus.DOWNLOAD_SUCCESS);
      expect(primaryActionFor(successApk), DownloadAction.install);
    });

    test('SUCCESS 且非 .apk 结尾 → null', () {
      final successPdf = _item(
        DownloadStatus.DOWNLOAD_SUCCESS,
        fileName: 'manual.pdf',
      );
      expect(primaryActionFor(successPdf), isNull);
    });
  });
}
