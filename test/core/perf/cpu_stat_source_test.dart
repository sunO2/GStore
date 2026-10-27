// `/proc/stat` 特权兜底解析 / 增量测试（无需 Shizuku / 真机）。
import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/core/perf/cpu_stat_source.dart';

const String _statA = '''
cpu  100 0 100 800 0 0 0 0 0 0
cpu0 50 0 50 400 0 0 0 0 0 0
cpu1 50 0 50 400 0 0 0 0 0 0
intr 0
ctxt 0
''';

const String _statB = '''
cpu  200 0 150 1150 0 0 0 0 0 0
cpu0 100 0 75 575 0 0 0 0 0 0
cpu1 100 0 75 575 0 0 0 0 0 0
intr 0
ctxt 0
''';

String _withSentinel(String stat) => '$stat\nGSTORE_RESULT ok=1\n';

void main() {
  test('parseProcStatText 解析聚合与逐核（含哨兵行）', () {
    final snapshot = parseProcStatText(_withSentinel(_statA));
    expect(snapshot, isNotNull);
    expect(snapshot!.aggregate.total, 1000);
    expect(snapshot.aggregate.idle, 800);
    expect(snapshot.perCore.keys, <int>[0, 1]);
    expect(snapshot.perCore[0]!.total, 500);
    expect(snapshot.perCore[0]!.idle, 400);
  });

  test('parseProcStatText 无聚合行 → null', () {
    expect(parseProcStatText('cpu0 1 1 1 1\n'), isNull);
  });

  test('cpuUsageDelta：Δtotal=0 或回退 → null', () {
    expect(
      cpuUsageDelta(
        const CpuTick(total: 100, idle: 80),
        const CpuTick(total: 100, idle: 80),
      ),
      isNull,
    );
  });

  test('CpuStatReader：首拍建基线，第二拍计算逐核占用', () async {
    var output = _withSentinel(_statA);
    final reader = CpuStatReader(runner: (_) async => output);

    expect(await reader.sample(), isNull, reason: '首次仅建立基线');

    output = _withSentinel(_statB);
    final sample = await reader.sample();
    expect(sample, isNotNull);
    // 聚合：Δtotal=500，Δidle=350 → 30%
    expect(sample!.usagePercent, closeTo(30, 0.0001));
    expect(sample.perCoreById[0], closeTo(30, 0.0001));
    expect(sample.perCoreById[1], closeTo(30, 0.0001));
  });

  test('CpuStatReader：runner 无输出 → null（绝不抛出）', () async {
    final reader = CpuStatReader(runner: (_) async => null);
    expect(await reader.sample(), isNull);
  });

  test('CpuStatReader：命令失败（无哨兵）→ null', () async {
    final reader = CpuStatReader(runner: (_) async => 'cat: /proc/stat: Permission denied\n');
    expect(await reader.sample(), isNull);
  });
}
