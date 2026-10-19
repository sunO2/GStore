import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/core/perf/fps_session.dart';

void main() {
  test('fromRecording：avg/min/max/末值/时长 正确', () {
    final session = FpsSession.fromRecording(
      id: 'x',
      label: 'L',
      startMs: 1000,
      endMs: 4000,
      samples: const <double>[60, 60, 30],
    );
    expect(session.avg, closeTo(50, 1e-9));
    expect(session.min, 30);
    expect(session.max, 60);
    expect(session.fps, 30);
    expect(session.frameCount, 3);
    expect(session.sampleCount, 3);
    expect(session.durationMs, 3000);
  });

  test('fromRecording：过滤 NaN / Infinity / 负值', () {
    final session = FpsSession.fromRecording(
      id: 'x',
      label: 'L',
      startMs: 0,
      endMs: 1000,
      samples: <double>[60, double.nan, -5, double.infinity, 30],
    );
    expect(session.samples, <double>[60, 30]);
    expect(session.avg, 45);
    expect(session.min, 30);
    expect(session.max, 60);
  });

  test('空会话：统计为 0，时长非负', () {
    final session = FpsSession.fromRecording(
      id: 'e',
      label: 'L',
      startMs: 500,
      endMs: 400,
      samples: const <double>[],
    );
    expect(session.avg, 0);
    expect(session.min, 0);
    expect(session.max, 0);
    expect(session.fps, 0);
    expect(session.frameCount, 0);
    expect(session.durationMs, 0);
  });

  test('toJson / fromJson 往返', () {
    final session = FpsSession.fromRecording(
      id: 'id1',
      package: 'com.x',
      label: '会话',
      startMs: 10,
      endMs: 2000,
      samples: const <double>[50, 55],
      source: 'latency',
    );
    final back = FpsSession.fromJson(session.toJson());
    expect(back.id, 'id1');
    expect(back.package, 'com.x');
    expect(back.label, '会话');
    expect(back.startMs, 10);
    expect(back.endMs, 2000);
    expect(back.samples, <double>[50, 55]);
    expect(back.avg, session.avg);
    expect(back.min, 50);
    expect(back.max, 55);
    expect(back.source, 'latency');
    expect(back.durationMs, 1990);
  });

  test('toJson / fromJson：scene-parity 新字段往返 + sessionId 别名', () {
    final session = FpsSession.fromRecording(
      id: 'id9',
      package: 'com.x',
      label: '会话',
      startMs: 10,
      endMs: 2000,
      samples: const <double>[50, 55],
      source: 'latency',
      avgPower: 1.234,
      viewSize: '1080.0x2340.0',
      mode: '均衡',
      temperatures: const <double>[41.5, 43.0, 46.2],
    );
    // sessionId 是 id 的别名（不是新字段）。
    expect(session.sessionId, 'id9');
    final json = session.toJson();
    expect(json['avg_power'], 1.234);
    expect(json['view_size'], '1080.0x2340.0');
    expect(json['mode'], '均衡');
    expect(json['temperatures'], <double>[41.5, 43.0, 46.2]);
    // 别名不写 JSON（仍只写 id）。
    expect(json.containsKey('session_id'), isFalse);

    final back = FpsSession.fromJson(json);
    expect(back.id, 'id9');
    expect(back.sessionId, 'id9');
    expect(back.avgPower, 1.234);
    expect(back.viewSize, '1080.0x2340.0');
    expect(back.mode, '均衡');
    expect(back.temperatures, <double>[41.5, 43.0, 46.2]);
    expect(back, session);
  });

  test('fromJson：旧 JSON（无新字段）→ 安全默认，不抛出', () {
    // 模拟 todo 14 之前落盘的 JSON（无 avg_power/view_size/mode/temperatures）。
    final legacy = <String, dynamic>{
      'id': 'old1',
      'package': null,
      'label': '旧会话',
      'start_ms': 0,
      'end_ms': 1000,
      'samples': <dynamic>[60, 60],
      'fps': 60,
      'avg': 60,
      'min': 60,
      'max': 60,
      'source': null,
    };
    final session = FpsSession.fromJson(legacy);
    expect(session.id, 'old1');
    expect(session.sessionId, 'old1');
    expect(session.avgPower, 0);
    expect(session.viewSize, '');
    expect(session.mode, '');
    expect(session.temperatures, isEmpty);
  });

  test('fromJson：新字段非法/畸形 → 降级为非有限被过滤，不抛出', () {
    final session = FpsSession.fromJson(<String, dynamic>{
      'samples': <dynamic>[],
      'avg_power': 'not-a-number',
      'view_size': null,
      'mode': 42,
      'temperatures': <dynamic>['41.5', double.nan, double.infinity, 'bad', -3],
      // 无 `id` 时接受 Scene 命名的 `session_id` 别名输入。
      'session_id': 'scene-alias',
    });
    expect(session.id, 'scene-alias');
    expect(session.sessionId, 'scene-alias');
    expect(session.avgPower, 0);
    expect(session.viewSize, '');
    expect(session.mode, '42');
    expect(session.temperatures, <double>[41.5, -3]);
  });

  test('fromJson：`id` 存在时优先于 `session_id` 别名', () {
    final session = FpsSession.fromJson(<String, dynamic>{
      'id': 'primary',
      'session_id': 'scene-alias',
    });
    expect(session.id, 'primary');
    expect(session.sessionId, 'primary');
  });

  test('fromJson：缺失 / 非法字段降级并由样本重算统计', () {
    final session = FpsSession.fromJson(<String, dynamic>{
      'id': 123,
      'start_ms': '100',
      'end_ms': null,
      'samples': <dynamic>['60', 30, 'bad', 999],
      'avg': 'not-a-number',
    });
    expect(session.id, '123');
    expect(session.package, isNull);
    expect(session.label, '');
    expect(session.startMs, 100);
    expect(session.endMs, 0);
    expect(session.samples, <double>[60, 30, 999]);
    expect(session.avg, closeTo((60 + 30 + 999) / 3, 1e-9));
    expect(session.min, 30);
    expect(session.max, 999);
  });

  test('buildFpsSessionCsv：含元信息与样本块', () {
    final session = FpsSession.fromRecording(
      id: 'id1',
      label: '会话',
      startMs: 0,
      endMs: 2000,
      samples: const <double>[60, 30],
    );
    final csv = buildFpsSessionCsv(session);
    expect(csv, contains('id,id1'));
    expect(csv, contains('sample_count,2'));
    expect(csv, contains('avg,45.0'));
    expect(csv, contains('min,30.0'));
    expect(csv, contains('max,60.0'));
    expect(csv, contains('index,fps'));
    expect(csv, contains('0,60.0'));
    expect(csv, contains('1,30.0'));
  });

  test('buildFpsSessionCsv：Scene-parity 列对齐（旧列仍保留）', () {
    final session = FpsSession.fromRecording(
      id: 'id2',
      label: '会话',
      startMs: 0,
      endMs: 2000,
      samples: const <double>[60, 30],
      mode: '均衡',
      viewSize: '1080.0x2340.0',
      avgPower: 1.25,
      temperatures: const <double>[46, 41.5],
    );
    final csv = buildFpsSessionCsv(session);
    // 旧列不变。
    expect(csv, contains('id,id2'));
    expect(csv, contains('sample_count,2'));
    expect(csv, contains('avg,45.0'));
    expect(csv, contains('min,30.0'));
    expect(csv, contains('max,60.0'));
    expect(csv, contains('index,fps'));
    // 新列：raw 字段 + 复用 fps_analysis 的派生比率。
    expect(csv, contains('mode,均衡'));
    expect(csv, contains('view_size,1080.0x2340.0'));
    expect(csv, contains('avg_power,1.25'));
    // [60, 30] → 1/2 流畅；[46, 41.5] → 1/2 高温。
    expect(csv, contains('fluency_ratio,0.5'));
    expect(csv, contains('high_temp_ratio,0.5'));
  });

  test('buildFpsSessionCsv：空会话仍产出有效表头，比率归零', () {
    final session = FpsSession.fromRecording(
      id: 'e2',
      label: '空会话',
      startMs: 0,
      endMs: 0,
      samples: const <double>[],
    );
    final csv = buildFpsSessionCsv(session);
    expect(csv, contains('key,value'));
    expect(csv, contains('sample_count,0'));
    expect(csv, contains('fluency_ratio,0.0'));
    expect(csv, contains('high_temp_ratio,0.0'));
    expect(csv, contains('avg_power,0.0'));
    expect(csv, contains('index,fps'));
  });

  test('formatFpsSessionDuration：秒 / 分秒 / 负值', () {
    expect(formatFpsSessionDuration(0), '0秒');
    expect(formatFpsSessionDuration(45000), '45秒');
    expect(formatFpsSessionDuration(83000), '1分23秒');
    expect(formatFpsSessionDuration(-100), '0秒');
  });

  test('FpsStats.fromSamples：非有限 / 负值被忽略', () {
    final stats = FpsStats.fromSamples(<double>[
      double.nan,
      -1,
      double.infinity,
      60,
      40,
    ]);
    expect(stats.count, 2);
    expect(stats.avg, 50);
    expect(stats.min, 40);
    expect(stats.max, 60);
    expect(stats.fps, 40);
  });
}
