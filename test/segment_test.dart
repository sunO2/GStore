import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/download/segment/segment_planner.dart';
import 'package:gstore/core/download/segment/segment_merger.dart';

void main() {
  group('SegmentPlanner.calcSegmentCountForSize', () {
    test('小文件单段', () {
      expect(SegmentPlanner.calcSegmentCountForSize(1024 * 1024), 1);
      expect(SegmentPlanner.calcSegmentCountForSize(1), 1);
    });

    test('中等文件自适应分段', () {
      // 10MB → 2 段（10/8 向上取整 = 2）
      expect(SegmentPlanner.calcSegmentCountForSize(10 * 1024 * 1024), 2);
      // 17MB → 3 段
      expect(SegmentPlanner.calcSegmentCountForSize(17 * 1024 * 1024), 3);
    });

    test('超大文件限制最大 8 段', () {
      expect(
          SegmentPlanner.calcSegmentCountForSize(100 * 1024 * 1024), 8);
      expect(
          SegmentPlanner.calcSegmentCountForSize(1024 * 1024 * 1024), 8);
    });

    test('刚好一段大小', () {
      // 8MB → 1 段
      expect(SegmentPlanner.calcSegmentCountForSize(8 * 1024 * 1024), 1);
    });
  });

  group('SegmentPlanner.divideSegments', () {
    test('分段覆盖完整范围', () {
      final segments = SegmentPlanner.divideSegments(100, 4);
      expect(segments.length, 4);
      // 首段从 0 开始，末段结束于 total-1
      expect(segments.first.startByte, 0);
      expect(segments.last.endByte, 99);
      // 每段连续无重叠
      for (var i = 1; i < segments.length; i++) {
        expect(segments[i].startByte, segments[i - 1].endByte + 1);
      }
      // 总字节数 = totalBytes
      final total = segments.fold<int>(
          0, (sum, s) => sum + s.length);
      expect(total, 100);
    });

    test('单段覆盖全部', () {
      final segments = SegmentPlanner.divideSegments(50, 1);
      expect(segments.length, 1);
      expect(segments[0].startByte, 0);
      expect(segments[0].endByte, 49);
      expect(segments[0].length, 50);
    });

    test('余数正确分配', () {
      // 10 字节分 4 段：大小 = 2,2,3,3（余数给前 2 段各 +1）
      final segments = SegmentPlanner.divideSegments(10, 4);
      expect(segments[0].length, 3);
      expect(segments[1].length, 3);
      expect(segments[2].length, 2);
      expect(segments[3].length, 2);
      expect(segments[3].endByte, 9);
    });

    test('Range 头格式', () {
      final segments = SegmentPlanner.divideSegments(100, 2);
      expect(segments[0].rangeHeader, 'bytes=0-49');
      expect(segments[1].rangeHeader, 'bytes=50-99');
    });

    test('part 文件路径', () {
      final segments = SegmentPlanner.divideSegments(100, 3);
      expect(segments[0].partPath('/tmp/a.apk'), '/tmp/a.apk.part0');
      expect(segments[2].partPath('/tmp/a.apk'), '/tmp/a.apk.part2');
    });
  });

  group('SegmentMerger', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('gstore_segment_test_');
    });

    tearDown(() {
      tempDir.deleteSync(recursive: true);
    });

    test('合并多个 part 文件为完整文件', () async {
      final savePath = '${tempDir.path}/app.apk';
      // 创建 3 个 part 文件
      File('$savePath.part0').writeAsStringSync('AAAA');
      File('$savePath.part1').writeAsStringSync('BBBB');
      File('$savePath.part2').writeAsStringSync('CC');

      final ok = await SegmentMerger.merge(
        savePath: savePath,
        segmentCount: 3,
      );

      expect(ok, true);
      // 最终文件内容按顺序拼接
      expect(File(savePath).readAsStringSync(), 'AAAABBBBCC');
      // part 文件已清理
      expect(File('$savePath.part0').existsSync(), false);
      expect(File('$savePath.part1').existsSync(), false);
      expect(File('$savePath.part2').existsSync(), false);
    });

    test('缺少 part 文件时返回 false', () async {
      final savePath = '${tempDir.path}/app.apk';
      File('$savePath.part0').writeAsStringSync('AAAA');
      // 缺 part1

      final ok = await SegmentMerger.merge(
        savePath: savePath,
        segmentCount: 3,
      );

      expect(ok, false);
    });

    test('cleanupParts 清理所有 part', () async {
      final savePath = '${tempDir.path}/app.apk';
      File('$savePath.part0').writeAsStringSync('A');
      File('$savePath.part1').writeAsStringSync('B');

      await SegmentMerger.cleanupParts(savePath, 2);

      expect(File('$savePath.part0').existsSync(), false);
      expect(File('$savePath.part1').existsSync(), false);
    });
  });
}
