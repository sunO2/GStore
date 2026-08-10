import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';

void main() {
  group('DownloadInfo.formattedSize', () {
    DownloadInfo make({int? size}) =>
        DownloadInfo(url: 'https://a/b.apk', name: 'b.apk', size: size);

    test('null 返回空串', () {
      expect(make(size: null).formattedSize, '');
    });

    test('B 单位', () {
      expect(make(size: 0).formattedSize, '0 B');
      expect(make(size: 512).formattedSize, '512 B');
      expect(make(size: 1023).formattedSize, '1023 B');
    });

    test('KB 单位', () {
      expect(make(size: 1024).formattedSize, '1.0 KB');
      expect(make(size: 2048).formattedSize, '2.0 KB');
      expect(make(size: 1536).formattedSize, '1.5 KB');
    });

    test('MB 单位', () {
      expect(make(size: 1024 * 1024).formattedSize, '1.0 MB');
      expect(make(size: 5 * 1024 * 1024).formattedSize, '5.0 MB');
    });

    test('GB 单位', () {
      expect(make(size: 1024 * 1024 * 1024).formattedSize, '1.00 GB');
      expect(make(size: 3 * 1024 * 1024 * 1024).formattedSize, '3.00 GB');
    });

    test('边界值', () {
      expect(make(size: 1024 * 1024 - 1).formattedSize, '1024.0 KB');
      expect(make(size: 1024 * 1024).formattedSize, '1.0 MB');
    });
  });
}
