import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';
import 'package:gstore/core/model/detail_extra_keys.dart';
import 'package:gstore/core/model/proxy/GitHubChannelDetailProxy.dart';
import 'package:gstore/core/model/proxy/VivoChannelDetailProxy.dart';
import 'package:gstore/core/model/proxy/HttpChannelDetailProxy.dart';
import 'package:gstore/core/model/proxy/FdroidChannelDetailProxy.dart';
import 'package:gstore/core/model/proxy/LocalDbChannelDetailProxy.dart';
import 'package:gstore/core/channel/impl/JsChannel.dart';

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

group('DownloadInfo.extra', () {
    test('extra 默认为 null', () {
      final info = DownloadInfo(url: 'https://a/b.apk', name: 'b.apk');
      expect(info.extra, isNull);
    });

    test('extra 可传入 Map<String, DownloadTag>', () {
      final info = DownloadInfo(
        url: 'https://a/b.apk',
        name: 'b.apk',
        extra: {
          'buildNum': const DownloadTag(text: '35'),
          'env': const DownloadTag(text: 'prd'),
          'updateTime': const DownloadTag(text: '2024-03-15'),
        },
      );
      expect(info.extra, isNotNull);
      expect(info.extra!['buildNum']?.text, '35');
      expect(info.extra!['env']?.text, 'prd');
      expect(info.extra!['updateTime']?.text, '2024-03-15');
    });

    test('extra 不影响功能字段构造参数', () {
      final info = DownloadInfo(
        url: 'https://a/b.apk',
        name: 'b.apk',
        size: 1024,
        version: '1.0',
        extra: {
          'buildNum': const DownloadTag(text: '35'),
          'env': const DownloadTag(text: 'prd'),
        },
      );
      expect(info.size, 1024);
      expect(info.version, '1.0');
      expect(info.extra!['buildNum']?.text, '35');
      expect(info.extra!['env']?.text, 'prd');
    });
  });

  group('DownloadInfo.updateTimeText', () {
    test('读 extra["updateTime"] 标签文本', () {
      final info = DownloadInfo(
        url: 'https://a/b.apk',
        name: 'b.apk',
        extra: {'updateTime': const DownloadTag(text: '2024-06-01')},
      );
      expect(info.updateTimeText, '2024-06-01');
    });

    test('extra 为 null 返回 null', () {
      final info = DownloadInfo(
        url: 'https://a/b.apk',
        name: 'b.apk',
        publishedAt: DateTime(2024, 3, 15),
      );
      expect(info.updateTimeText, isNull);
    });

    test('extra 无 updateTime 键返回 null（不回退 publishedAt）', () {
      final info = DownloadInfo(
        url: 'https://a/b.apk',
        name: 'b.apk',
        extra: {'buildNum': const DownloadTag(text: '35')},
        publishedAt: DateTime(2024, 3, 15),
      );
      expect(info.updateTimeText, isNull);
    });

    test('extra 和 publishedAt 都为 null 返回 null', () {
      final info = DownloadInfo(url: 'https://a/b.apk', name: 'b.apk');
      expect(info.updateTimeText, isNull);
    });

    test('extra updateTime 为空文本返回 null', () {
      final info = DownloadInfo(
        url: 'https://a/b.apk',
        name: 'b.apk',
        extra: {'updateTime': const DownloadTag(text: '')},
        publishedAt: DateTime(2024, 3, 15),
      );
      expect(info.updateTimeText, isNull);
    });
  });

  group('Proxy 缺键容错（extra 默认值不崩）', () {
    /// 所有 proxy 的 download 构造入口：item 缺 size/platform/downloadCount/version 时不崩
    final minimalItem = <String, dynamic>{
      'url': 'https://a/b.apk',
      'name': 'b.apk',
    };

    group('GitHubChannelDetailProxy', () {
      test('全部缺键 → extra 四项均为空文本', () {
        final proxy = GitHubChannelDetailProxy({
          'downloads': [minimalItem],
        });
        final dl = proxy.downloads;
        expect(dl.length, 1);
        final extra = dl[0].extra!;
        expect(extra[DownloadItemExtra.size]?.text, '');
        expect(extra[DownloadItemExtra.platform]?.text, '');
        expect(extra[DownloadItemExtra.downloadCount]?.text, '');
        expect(extra[DownloadItemExtra.version]?.text, '');
      });

      test('部分缺键 → 不缺的键正常填充', () {
        final proxy = GitHubChannelDetailProxy({
          'downloads': [
            {
              ...minimalItem,
              'size': 2048,
              'version': '2.0',
            },
          ],
        });
        final dl = proxy.downloads;
        expect(dl.length, 1);
        final extra = dl[0].extra!;
        expect(extra[DownloadItemExtra.size]?.text, '2.0 KB');
        expect(extra[DownloadItemExtra.platform]?.text, '');
        expect(extra[DownloadItemExtra.downloadCount]?.text, '');
        expect(extra[DownloadItemExtra.version]?.text, '2.0');
      });
    });

    group('VivoChannelDetailProxy', () {
      test('全部缺键 → extra 四项均为空文本', () {
        final proxy = VivoChannelDetailProxy({
          'downloads': [minimalItem],
        });
        final dl = proxy.downloads;
        expect(dl.length, 1);
        final extra = dl[0].extra!;
        expect(extra[DownloadItemExtra.size]?.text, '');
        expect(extra[DownloadItemExtra.platform]?.text, '');
        expect(extra[DownloadItemExtra.downloadCount]?.text, '');
        expect(extra[DownloadItemExtra.version]?.text, '');
      });

      test('size 缺键 → _formatSize(null) 返回空', () {
        final proxy = VivoChannelDetailProxy({
          'downloads': [
            {
              ...minimalItem,
              'platform': 'android',
              'version': '1.0',
            },
          ],
        });
        final dl = proxy.downloads;
        expect(dl.length, 1);
        final extra = dl[0].extra!;
        expect(extra[DownloadItemExtra.size]?.text, '');
        expect(extra[DownloadItemExtra.platform]?.text, 'android');
        expect(extra[DownloadItemExtra.version]?.text, '1.0');
      });
    });

    group('HttpChannelDetailProxy', () {
      test('全部缺键 → extra 四项均为空文本', () {
        final proxy = HttpChannelDetailProxy({
          'downloads': [minimalItem],
        });
        final dl = proxy.downloads;
        expect(dl.length, 1);
        final extra = dl[0].extra!;
        expect(extra[DownloadItemExtra.size]?.text, '');
        expect(extra[DownloadItemExtra.platform]?.text, '');
        expect(extra[DownloadItemExtra.downloadCount]?.text, '');
        expect(extra[DownloadItemExtra.version]?.text, '');
      });
    });

    group('FdroidChannelDetailProxy', () {
      test('全部缺键 → extra 为空 Map（if 守卫跳过，非 null）', () {
        final proxy = FdroidChannelDetailProxy({
          'downloads': [minimalItem],
        });
        final dl = proxy.downloads;
        expect(dl.length, 1);
        // Fdroid 使用 if 守卫，size/platform/version 为 null/空时不加入 extra
        // 但 Dart 空 map 字面量 {} 产生非 null 的空 Map
        final extra = dl[0].extra!;
        expect(extra, isEmpty);
      });

      test('部分缺键 → 不缺的键正常填充', () {
        final proxy = FdroidChannelDetailProxy({
          'downloads': [
            {
              ...minimalItem,
              'size': 4096,
              'platform': 'arm64-v8a',
            },
          ],
        });
        final dl = proxy.downloads;
        expect(dl.length, 1);
        final extra = dl[0].extra!;
        expect(extra[DownloadItemExtra.size]?.text, '4.0 KB');
        expect(extra[DownloadItemExtra.platform]?.text, 'arm64-v8a');
        expect(extra.containsKey(DownloadItemExtra.version), isFalse);
      });
    });

    group('LocalDbChannelDetailProxy', () {
      test('缺键 → extra 四项均为空文本', () {
        final proxy = LocalDbChannelDetailProxy({
          'downloads': [minimalItem],
        });
        final dl = proxy.downloads;
        expect(dl.length, 1);
        final extra = dl[0].extra!;
        expect(extra[DownloadItemExtra.size]?.text, '');
        expect(extra[DownloadItemExtra.platform]?.text, '');
        expect(extra[DownloadItemExtra.downloadCount]?.text, '');
        expect(extra[DownloadItemExtra.version]?.text, '');
      });
    });

    group('JsChannelDetailProxy', () {
      test('item 缺 extra → extra 为 null', () {
        final proxy = JsChannelDetailProxy({
          'downloads': [minimalItem],
        });
        final dl = proxy.downloads;
        expect(dl.length, 1);
        // _parseJsExtra(null) → null
        expect(dl[0].extra, isNull);
      });

      test('item extra 为空 Map → extra 为 null（_parseJsExtra 空 map 返回 null）', () {
        final proxy = JsChannelDetailProxy({
          'downloads': [
            {
              ...minimalItem,
              'extra': <String, dynamic>{},
            },
          ],
        });
        final dl = proxy.downloads;
        expect(dl.length, 1);
        expect(dl[0].extra, isNull);
      });

      test('item extra 含键值 → 正常解析', () {
        final proxy = JsChannelDetailProxy({
          'downloads': [
            {
              ...minimalItem,
              'extra': {
                'updateTime': {'text': '2024-06-01', 'icon': 'update'},
                'buildNum': {'text': '42'},
              },
            },
          ],
        });
        final dl = proxy.downloads;
        expect(dl.length, 1);
        final extra = dl[0].extra!;
        expect(extra['updateTime']?.text, '2024-06-01');
        expect(extra['updateTime']?.iconName, 'update');
        expect(extra['buildNum']?.text, '42');
      });

      test('item 缺 url/name → 默认为空串不崩', () {
        final proxy = JsChannelDetailProxy({
          'downloads': [
            <String, dynamic>{},
          ],
        });
        final dl = proxy.downloads;
        expect(dl.length, 1);
        expect(dl[0].url, '');
        expect(dl[0].name, '');
        expect(dl[0].extra, isNull);
      });

      test('downloadable 缺键 → 默认为 true', () {
        final proxy = JsChannelDetailProxy({
          'downloads': [minimalItem],
        });
        final dl = proxy.downloads;
        expect(dl.length, 1);
        expect(dl[0].downloadable, isTrue);
      });
    });
  });
}
