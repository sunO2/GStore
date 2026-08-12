import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/update/update_time_format.dart';

void main() {
  final now = DateTime(2026, 8, 12, 20, 30, 0);

  test('未检测（null）：显示"尚未检测"', () {
    expect(formatLastChecked(null, now), '尚未检测');
  });

  test('1 分钟内：显示"刚刚"', () {
    expect(formatLastChecked(now.subtract(const Duration(seconds: 30)), now),
        '刚刚');
  });

  test('1 小时内：显示"x 分钟前"', () {
    expect(formatLastChecked(now.subtract(const Duration(minutes: 5)), now),
        '5 分钟前');
    expect(formatLastChecked(now.subtract(const Duration(minutes: 59)), now),
        '59 分钟前');
  });

  test('刚好 1 小时：按绝对时间显示', () {
    expect(
      formatLastChecked(now.subtract(const Duration(hours: 1)), now),
      '2026-08-12 19:30',
    );
  });

  test('超过 1 小时：显示实际日期时间（补零）', () {
    final last = DateTime(2026, 8, 11, 9, 5);
    expect(formatLastChecked(last, now), '2026-08-11 09:05');
  });
}
