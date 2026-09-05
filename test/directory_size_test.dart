import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/utils/unit.dart';

void main() {
  group('directorySize', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('dir_size_test');
    });

    tearDown(() async {
      if (await tmp.exists()) {
        await tmp.delete(recursive: true);
      }
    });

    test('空目录返回 0', () async {
      expect(await directorySize(tmp), 0);
    });

    test('统计子目录文件总字节', () async {
      final sub = Directory('${tmp.path}/sub')..createSync(recursive: true);
      File('${sub.path}/a.bin').writeAsBytesSync(List.filled(10, 1));
      File('${tmp.path}/b.bin').writeAsBytesSync(List.filled(20, 2));
      Directory('${sub.path}/deep').createSync(recursive: true);
      File('${sub.path}/deep/c.bin').writeAsBytesSync(List.filled(30, 3));

      expect(await directorySize(tmp), 60);
    });

    test('不存在的目录返回 0', () async {
      expect(await directorySize(Directory('${tmp.path}/nope')), 0);
    });
  });

  group('byteSize', () {
    test('格式化各量级', () {
      expect(byteSize(0), '0 B');
      expect(byteSize(512), '512 B');
      expect(byteSize(2048), '2.00 KB');
      expect(byteSize(3 * MB), '3.00 MB');
      expect(byteSize(2 * GB), '2.00 GB');
    });
  });
}
