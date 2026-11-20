// ignore_for_file: depend_on_referenced_packages
// Flutter 性能采样辅助脚本（工具，不参与 App 构建）。
//
// 连接 `flutter run --profile` 暴露的 VM Service，用框架/引擎自己的
// Timeline 事件（`Frame` = UI 线程构建，`GPURasterizer::Draw` = 光栅线程）
// 统计一次交互窗口内的帧耗时。数据来源与 DevTools Performance 页一致。
//
// 用法：
//   dart run tool/perf_probe.dart <ws-uri> mark            # 清空时间线
//   dart run tool/perf_probe.dart <ws-uri> builds on|off   # 记录 widget 重建事件
//   dart run tool/perf_probe.dart <ws-uri> report [out]    # 拉取并打印统计
import 'dart:convert';
import 'dart:io';

import 'package:flutter_driver/src/driver/timeline.dart' as fd;
import 'package:flutter_driver/src/driver/timeline_summary.dart';
import 'package:vm_service/vm_service_io.dart';

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    stderr.writeln('usage: perf_probe.dart <ws-uri> mark|builds on|off|report [out.json]');
    exit(64);
  }
  final uri = args[0];
  final command = args[1];
  final out = args.length > 2 ? args[2] : null;

  final service = await vmServiceConnectUri(uri);
  try {
    final vm = await service.getVM();
    final isolateId = vm.isolates!.first.id!;

    if (command == 'mark') {
      await service.clearVMTimeline();
      stdout.writeln('timeline cleared');
      return;
    }
    if (command == 'builds') {
      final enable = out == 'on';
      await service.callServiceExtension(
        'ext.flutter.profileUserWidgetBuilds',
        isolateId: isolateId,
        args: <String, String>{'enabled': '$enable'},
      );
      stdout.writeln('user widget build events: $enable');
      return;
    }
    if (command != 'report') {
      stderr.writeln('unknown command: $command');
      exit(64);
    }

    final timeline = await service.getVMTimeline();
    final json = timeline.json ?? <String, dynamic>{};
    if (out != null) {
      File(out).writeAsStringSync(const JsonEncoder.withIndent(' ').convert(json));
    }
    final parsed = fd.Timeline.fromJson(json);
    final summary = TimelineSummary.summarize(parsed);

    double p(double value) => (value * 100).roundToDouble() / 100;
    // Frame 事件是 async b/e 成对记录，GPU 光栅是 B/E；Begin 数量即帧数。
    var frames = 0;
    var rasters = 0;
    for (final event in parsed.events ?? const <fd.TimelineEvent>[]) {
      if (event.name == kBuildFrameEventName && event.phase == 'b') frames++;
      if (event.name == kRasterizeFrameEventName && event.phase == 'B') rasters++;
    }

    // widget 重建发生在 UI 线程：以 Frame 事件的线程为准，排除 raster/IO 线程。
    final uiTids = <int>{
      for (final event in parsed.events ?? const <fd.TimelineEvent>[])
        if (event.name == kBuildFrameEventName && event.phase == 'b' && event.threadId != null)
          event.threadId!,
    };
    // widget 重建事件按 tid 嵌套（B/E），用栈算 self time。
    final stacks = <int, List<_Span>>{};
    final stats = <String, _BuildStat>{};
    for (final event in parsed.events ?? const <fd.TimelineEvent>[]) {
      if (!uiTids.contains(event.threadId)) continue;
      final name = event.name ?? '';
      // 过滤引擎/合成器事件（含 :: 或全大写），只看 Dart widget。
      if (name.contains('::') || name == name.toUpperCase()) continue;
      final stack = stacks.putIfAbsent(event.threadId ?? 0, () => <_Span>[]);
      if (event.phase == 'B') {
        stack.add(_Span(event.name ?? '?', event.timestampMicros ?? 0));
      } else if (event.phase == 'E' && stack.isNotEmpty) {
        final span = stack.removeLast();
        final durationMicros = (event.timestampMicros ?? span.startMicros).toInt() - span.startMicros;
        final stat = stats.putIfAbsent(span.name, () => _BuildStat());
        stat.count++;
        stat.totalMicros += durationMicros;
        stat.selfMicros += durationMicros - span.childrenMicros;
        if (stack.isNotEmpty) {
          stack.last.childrenMicros += durationMicros;
        }
      }
    }
    final top = stats.entries
        .where((e) => e.value.count > 0 && e.key.isNotEmpty)
        .toList()
      ..sort((a, b) => b.value.selfMicros.compareTo(a.value.selfMicros));

    stdout.writeln(jsonEncode({
      'framesBuild': frames,
      'framesRaster': rasters,
      'buildAvgMs': p(summary.computeAverageFrameBuildTimeMillis()),
      'buildP90Ms': p(summary.computePercentileFrameBuildTimeMillis(90)),
      'buildP99Ms': p(summary.computePercentileFrameBuildTimeMillis(99)),
      'buildWorstMs': p(summary.computeWorstFrameBuildTimeMillis()),
      'buildOver16ms': summary.computeMissedFrameBuildBudgetCount(),
      'rasterAvgMs': p(summary.computeAverageFrameRasterizerTimeMillis()),
      'rasterP90Ms': p(summary.computePercentileFrameRasterizerTimeMillis(90)),
      'rasterP99Ms': p(summary.computePercentileFrameRasterizerTimeMillis(99)),
      'rasterWorstMs': p(summary.computeWorstFrameRasterizerTimeMillis()),
      'rasterOver16ms': summary.computeMissedFrameRasterizerBudgetCount(),
      'topWidgets': [
        for (final entry in top.take(15))
          {
            'name': entry.key,
            'count': entry.value.count,
            'selfMs': p(entry.value.selfMicros / 1000),
            'totalMs': p(entry.value.totalMicros / 1000),
          }
      ],
    }));
  } finally {
    await service.dispose();
  }
}

class _Span {
  _Span(this.name, this.startMicros) : childrenMicros = 0;

  final String name;
  final int startMicros;
  int childrenMicros;
}

class _BuildStat {
  int count = 0;
  int totalMicros = 0;
  int selfMicros = 0;
}
