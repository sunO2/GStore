import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/core/agent/agent_tool_module.dart';
import 'package:gstore/core/agent/tools/perf_tools.dart';
import 'package:gstore/core/module/app_modules.dart';
import 'package:gstore/core/perf/frame_monitor.dart';
import 'package:gstore/core/perf/frame_stats.dart';
import 'package:gstore/core/perf/third_party_perf_service.dart';
import 'package:gstore/core/rust/perf/PerfContract.dart';
import 'package:gstore/core/rust/perf/PerfModule.dart';

/// 假 PerfModule：返回固定快照 / 抛「模块未安装」，不触碰 FFI。
class _FakePerfModule extends PerfModule {
  _FakePerfModule({this.snapshotResult, this.unavailable = false});

  final PerfSnapshot? snapshotResult;
  final bool unavailable;

  @override
  Future<PerfSnapshot> snapshot({
    bool includeProcesses = false,
    int? processLimit,
  }) async {
    if (unavailable) throw PerfModuleUnavailableException();
    return snapshotResult ?? const PerfSnapshot();
  }
}

/// 假第三方服务：仅覆写 Shizuku 检测与采样，不触碰 Shizuku / 平台通道。
class _FakeThirdPartyService extends ThirdPartyPerfService {
  _FakeThirdPartyService({required this.shizukuOk, this.metrics});

  final bool shizukuOk;
  final ThirdPartyAppMetrics? metrics;

  @override
  Future<bool> refreshShizukuStatus() async => shizukuOk;

  @override
  Future<ThirdPartyAppMetrics> sample(
    String package, {
    int? prevFrameCount,
    int? prevTsMs,
  }) async =>
      metrics ?? ThirdPartyAppMetrics(package: package);
}

/// 假帧监控：直接返回注入的统计快照。
class _FakeFrameMonitor extends FrameMonitor {
  _FakeFrameMonitor(this._stats);

  final FrameStats _stats;

  @override
  FrameStats get latestStats => _stats;
}

PerfSnapshot _sampleSnapshot() => const PerfSnapshot(
      tsMs: 1729000000000,
      cpu: CpuReport(
        usagePercent: 42.5,
        coreCount: 8,
        loadavg: PerfLoadAvg(load1: 1.2, load5: 0.9, load15: 0.7),
      ),
      memory: MemoryReport(usedKb: 2048000, totalKb: 4096000, usedPercent: 55.0),
      battery: BatteryReport(
        present: true,
        capacityPercent: 88.0,
        temperatureC: 30.0,
      ),
      thermal: ThermalReport(zoneCount: 3, maxTempC: 45.0),
    );

AgentToolModule _tool(
  String name, {
  PerfModule? perfModule,
  ThirdPartyPerfService? thirdParty,
  FrameMonitor? frameMonitor,
}) {
  final tools = PerfTools(
    perfModule: perfModule,
    thirdParty: thirdParty,
    frameMonitor: frameMonitor,
  ).tools;
  return tools.firstWhere((t) => t.toolName == name);
}

Map<String, dynamic> _decode(String text) =>
    jsonDecode(text) as Map<String, dynamic>;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AgentToolsModule 工具清单（AgentService 实际消费集合）', () {
    test('并入 3 个 perf 工具，运行时注册生效', () {
      final names =
          AgentToolsModule().tools.map((t) => t.toolName).toList();
      expect(
        names,
        containsAll(<String>[
          'perfDeviceSnapshot',
          'perfThirdPartyMetrics',
          'perfFrameStats',
        ]),
        reason: 'AgentService 仅从 AgentToolsModule.tools 拉取工具；'
            '否则 perf 工具运行时永不注册',
      );
      expect(names.toSet().length, names.length,
          reason: '注册集合不得含重复 toolName');
    });
  });

  group('PerfTools 工具清单', () {
    test('导出 3 个只读工具且元数据完整', () {
      final tools = PerfTools().tools;
      expect(tools.length, 3);
      expect(
        tools.map((t) => t.toolName),
        containsAll(<String>[
          'perfDeviceSnapshot',
          'perfThirdPartyMetrics',
          'perfFrameStats',
        ]),
      );
      for (final t in tools) {
        expect(t.moduleName, 'agent_tool_${t.toolName}');
        expect(t.toolDescription.trim(), isNotEmpty);
        expect(t.enabled, isTrue);
      }
    });

    test('perfThirdPartyMetrics：package 必填、sort 可选', () {
      final tool = _tool('perfThirdPartyMetrics');
      final pkg = tool.toolParams.firstWhere((p) => p.name == 'package');
      expect(pkg.required, isTrue);
      final sort = tool.toolParams.firstWhere((p) => p.name == 'sort');
      expect(sort.required, isFalse);
    });

    test('context.cancelled 时直接返回「已取消」', () async {
      final tool = _tool(
        'perfDeviceSnapshot',
        perfModule: _FakePerfModule(snapshotResult: _sampleSnapshot()),
      );
      final result = await tool.execute(
        AgentToolContext(stopRequested: () => true),
        <String, dynamic>{},
      );
      expect(result, '已取消');
    });
  });

  group('perfDeviceSnapshot', () {
    test('成功：返回紧凑设备摘要 JSON（CPU/内存/电池/温度/负载）', () async {
      final tool = _tool(
        'perfDeviceSnapshot',
        perfModule: _FakePerfModule(snapshotResult: _sampleSnapshot()),
      );
      final json = _decode(
        await tool.execute(const AgentToolContext(), <String, dynamic>{}),
      );
      expect(json['available'], isTrue);
      expect(json['cpu_percent'], 42.5);
      expect(json['cores'], 8);
      expect(json['load1'], 1.2);
      expect(json['mem_used_percent'], 55.0);
      expect(json['mem_used_kb'], 2048000);
      expect(json['battery_percent'], 88.0);
      expect(json['temperature_c'], 45.0, reason: '优先温度区最大值');
      expect(json['thermal_max_c'], 45.0);
    });

    test('模块不可用：优雅降级且不抛异常', () async {
      final tool = _tool(
        'perfDeviceSnapshot',
        perfModule: _FakePerfModule(unavailable: true),
      );
      final json = _decode(
        await tool.execute(const AgentToolContext(), <String, dynamic>{}),
      );
      expect(json['available'], isFalse);
      expect(json['error'], 'perf_module_unavailable');
      expect(json['message'], contains('未安装'));
    });

    test('空快照：可用但指标为 null（不编造）', () async {
      final tool = _tool(
        'perfDeviceSnapshot',
        perfModule: _FakePerfModule(snapshotResult: const PerfSnapshot()),
      );
      final json = _decode(
        await tool.execute(const AgentToolContext(), <String, dynamic>{}),
      );
      expect(json['available'], isTrue);
      expect(json['cpu_percent'], isNull);
      expect(json['mem_used_percent'], isNull);
    });
  });

  group('perfThirdPartyMetrics', () {
    const metrics = ThirdPartyAppMetrics(
      package: 'com.demo.app',
      pid: 1234,
      uid: 10123,
      running: true,
      threads: 12,
      cpuPercent: 18.5,
      memPssKb: 123456,
      jankyFrames: 3,
      jankyPercent: 4.2,
      frameCount: 600,
      fps: 58.6,
      processes: <PerfProcessInfo>[
        PerfProcessInfo(pid: 1234, name: 'com.demo.app', rssKb: 90000),
        PerfProcessInfo(pid: 1235, name: 'com.demo.app:svc', rssKb: 33000),
      ],
    );

    test('成功：返回 CPU/内存 PSS/jank/FPS 与排序后的进程列表', () async {
      final tool = _tool(
        'perfThirdPartyMetrics',
        thirdParty: _FakeThirdPartyService(shizukuOk: true, metrics: metrics),
      );
      final json = _decode(
        await tool.execute(const AgentToolContext(), <String, dynamic>{
          'package': 'com.demo.app',
          'sort': 'rss',
        }),
      );
      expect(json['available'], isTrue);
      expect(json['package'], 'com.demo.app');
      expect(json['cpu_percent'], 18.5);
      expect(json['mem_pss_kb'], 123456);
      expect(json['janky_percent'], 4.2);
      expect(json['fps'], 58.6);
      final procs = (json['processes'] as List)
          .cast<Map<String, dynamic>>()
          .toList();
      expect(procs.length, 2);
      expect(procs.first['rss_kb'], 90000, reason: 'rss 降序');
      expect(procs.last['rss_kb'], 33000);
    });

    test('缺少 package：返回 missing_package，不调用服务', () async {
      final tool = _tool(
        'perfThirdPartyMetrics',
        thirdParty: _FakeThirdPartyService(shizukuOk: true),
      );
      final json = _decode(
        await tool.execute(const AgentToolContext(), <String, dynamic>{}),
      );
      expect(json['available'], isFalse);
      expect(json['error'], 'missing_package');
    });

    test('Shizuku 不可用：返回清晰提示', () async {
      final tool = _tool(
        'perfThirdPartyMetrics',
        thirdParty: _FakeThirdPartyService(shizukuOk: false),
      );
      final json = _decode(
        await tool.execute(const AgentToolContext(), <String, dynamic>{
          'package': 'com.demo.app',
        }),
      );
      expect(json['available'], isFalse);
      expect(json['error'], 'shizuku_unavailable');
      expect(json['message'], contains('Shizuku'));
    });
  });

  group('perfFrameStats', () {
    test('成功：返回 fps/jank/百分位等帧统计', () async {
      final acc = FrameStatsAccumulator();
      for (var i = 0; i < 10; i++) {
        acc.addFrame(
          buildUs: 8000,
          rasterUs: 4000,
          vsyncUs: 100,
          totalUs: 12000,
          vsyncTimestampUs: i * 16666,
        );
      }
      final tool = _tool(
        'perfFrameStats',
        frameMonitor: _FakeFrameMonitor(acc.snapshot()),
      );
      final json = _decode(
        await tool.execute(const AgentToolContext(), <String, dynamic>{}),
      );
      expect(json['available'], isTrue);
      expect(json['sampled_frames'], 10);
      expect(json['window_size'], 120);
      expect((json['fps'] as num).toDouble(), closeTo(60.0, 0.5));
      expect(json['jank_count'], 0);
      expect(json['budget_ms'], 16.666);
    });

    test('空统计：仍可用（fps=0）', () async {
      final tool = _tool(
        'perfFrameStats',
        frameMonitor: _FakeFrameMonitor(FrameStatsAccumulator().snapshot()),
      );
      final json = _decode(
        await tool.execute(const AgentToolContext(), <String, dynamic>{}),
      );
      expect(json['available'], isTrue);
      expect(json['sampled_frames'], 0);
      expect(json['fps'], 0);
    });
  });
}
