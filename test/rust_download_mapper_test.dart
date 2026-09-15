import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/download/model/download_task.dart';
import 'package:gstore/core/download/rust/rust_download_mapper.dart';

/// `RustDownloadMapper` 是「Rust 内核 → 面板」的唯一翻译点。
/// 这些用例锁死契约，避免以后改内核时面板状态错位。
void main() {
  Map<String, dynamic> dto({
    int status = 2,
    Object? etaSec,
    Object? segments,
  }) =>
      {
        'id': 7,
        'appId': 'com.example.app',
        'appName': '示例',
        'version': '1.2.3',
        'fileName': 'app.apk',
        'url': 'https://x/app.apk',
        'filePath': '/data/dl/app.apk',
        'total': 1000,
        'received': 400,
        'status': status,
        'speedBps': 2048,
        'etaSec': etaSec,
        'error': null,
        'segments': segments,
        'createdAt': 1700000000000,
        'updatedAt': 1700000001000,
      };

  group('RustDownloadMapper.fromDto', () {
    test('全字段映射正确（含时间戳为毫秒）', () {
      final t = RustDownloadMapper.fromDto(dto());

      expect(t.id, 7);
      expect(t.appId, 'com.example.app');
      expect(t.appName, '示例');
      expect(t.version, '1.2.3');
      expect(t.fileName, 'app.apk');
      expect(t.filePath, '/data/dl/app.apk');
      expect(t.total, 1000);
      expect(t.received, 400);
      expect(t.status, DownloadStatusEnum.downloading);
      expect(t.speedBps, 2048);
      expect(t.etaSec, isNull);
      expect(t.createdAt.millisecondsSinceEpoch, 1700000000000);
      expect(t.updatedAt.millisecondsSinceEpoch, 1700000001000);
    });

    test('状态索引与 Dart 枚举逐一对齐（内核判别值契约）', () {
      const expected = [
        DownloadStatusEnum.queued,
        DownloadStatusEnum.connecting,
        DownloadStatusEnum.downloading,
        DownloadStatusEnum.paused,
        DownloadStatusEnum.completed,
        DownloadStatusEnum.failed,
        DownloadStatusEnum.cancelled,
      ];
      for (var i = 0; i < expected.length; i++) {
        expect(RustDownloadMapper.fromDto(dto(status: i)).status, expected[i],
            reason: '索引 $i 必须是 ${expected[i].name}');
      }
    });

    test('越界状态索引直接报错，不静默给出错乱状态', () {
      expect(() => RustDownloadMapper.fromDto(dto(status: 99)),
          throwsA(isA<FormatException>()));
      expect(() => RustDownloadMapper.fromDto(dto(status: -1)),
          throwsA(isA<FormatException>()));
    });

    test('etaSec 有值时保留', () {
      expect(RustDownloadMapper.fromDto(dto(etaSec: 12)).etaSec, 12);
    });

    test('数字容忍 int/double/字符串三种形态', () {
      final t = RustDownloadMapper.fromDto({
        ...dto(),
        'total': 1000.0,
        'received': '400',
        'id': 7.0,
      });
      expect(t.total, 1000);
      expect(t.received, 400);
      expect(t.id, 7);
    });

    test('分段：缺失或空 → null；有值 → 完整映射', () {
      expect(RustDownloadMapper.fromDto(dto()).segments, isNull);
      expect(RustDownloadMapper.fromDto(dto(segments: [])).segments, isNull);

      final t = RustDownloadMapper.fromDto(dto(segments: [
        {'index': 0, 'startByte': 0, 'endByte': 499, 'received': 500},
      ]));
      expect(t.segments, hasLength(1));
      expect(t.segments!.first.startByte, 0);
      expect(t.segments!.first.endByte, 499);
      expect(t.segments!.first.received, 500);
    });
  });

  group('RustDownloadMapper.fromDtoList', () {
    test('跳过结构不符的条目而不是整体失败', () {
      final list = RustDownloadMapper.fromDtoList([
        dto(),
        'not-a-map',
        42,
        {...dto(status: 4)},
      ]);
      expect(list, hasLength(2));
      expect(list[1].status, DownloadStatusEnum.completed);
    });

    test('非列表输入返回空清单', () {
      expect(RustDownloadMapper.fromDtoList(null), isEmpty);
      expect(RustDownloadMapper.fromDtoList('x'), isEmpty);
    });
  });

  group('RustDownloadMapper.fromProgressEvent', () {
    test('进度事件按传输态字段映射（面板只关心进度/速率）', () {
      final t = RustDownloadMapper.fromProgressEvent({
        'taskId': 9,
        'status': 2,
        'total': 2048,
        'received': 1024,
        'speedBps': 512,
        'etaSec': 2,
      });
      expect(t.id, 9);
      expect(t.total, 2048);
      expect(t.received, 1024);
      expect(t.speedBps, 512);
      expect(t.etaSec, 2);
      expect(t.status, DownloadStatusEnum.downloading);
    });
  });
}
