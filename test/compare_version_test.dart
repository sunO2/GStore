import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/utils/unit.dart';

void main() {
  group('compareVersion', () {
    test('标准版本号', () {
      expect(compareVersion('1.2.3', '1.2.4'), 1);
      expect(compareVersion('1.2.3', '1.2.3'), 0);
      expect(compareVersion('1.2.3', '1.2.2'), -1);
    });

    test('位数不足', () {
      expect(compareVersion('1.2', '1.2.0'), 0);
      expect(compareVersion('1.2', '1.2.1'), 1);
      expect(compareVersion('2', '2.0.0'), 0);
    });

    test('含字母前缀 v', () {
      expect(compareVersion('v1', 'v2'), 1);
      expect(compareVersion('v2', 'v1'), -1);
      expect(compareVersion('v1.0', '1.0'), 0);
    });

    test('含 beta/alpha 后缀', () {
      expect(compareVersion('0-beta04', '0.9.0'), 1);
      expect(compareVersion('0-beta04', '0-beta03'), -1);
      // 数字部分相同（alpha 后缀不影响数字比较），视为相等
      expect(compareVersion('1.5.0-alpha', '1.5.0'), 0);
    });

    test('非数字版本', () {
      expect(compareVersion('unknown', '1.0.0'), 1);
      expect(compareVersion('unknown', 'unknown'), 0);
    });

    test('混合格式', () {
      expect(compareVersion('0.0.12', '0.0.27'), 1);
      expect(compareVersion('2024.1.1', '2023.12.31'), -1);
    });
  });
}
