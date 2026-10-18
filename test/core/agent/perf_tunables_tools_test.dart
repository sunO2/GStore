import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/core/agent/agent_tool_module.dart';
import 'package:gstore/core/agent/tools/perf_control_tools.dart';
import 'package:gstore/core/agent/tools/perf_tunables_tools.dart';
import 'package:gstore/core/module/app_modules.dart';
import 'package:gstore/core/perf/perf_capability_probe.dart';
import 'package:gstore/core/rust/perf/PerfContract.dart';
import 'package:gstore/core/rust/perf/PerfModule.dart';

// ==================== fixtures ====================

TunablesReport _tunables() => const TunablesReport(
      cpuClusters: <PerfCpuCluster>[
        PerfCpuCluster(
          policy: 'policy0',
          relatedCpus: <int>[0, 1, 2, 3],
          availableGovernors: <String>['schedutil', 'performance'],
          governor: 'schedutil',
          availableFrequenciesMhz: <double>[300, 1800],
          minFreqMhz: 300,
          maxFreqMhz: 1800,
        ),
      ],
      cpusets: <PerfCpuset>[
        PerfCpuset(name: 'top-app', cpus: '0-7', mems: '0'),
      ],
      thermalZones: <PerfThermalTunable>[
        PerfThermalTunable(zone: 'thermal_zone0', type: 'cpu', mode: 'enabled'),
      ],
      coolingDevices: <PerfCoolingTunable>[
        PerfCoolingTunable(device: 'cooling_device0', type: 'cpu', curState: 0, maxState: 8),
      ],
      gpu: PerfGpuTunables(
        availableFrequenciesMhz: <double>[200, 600],
        governorSource: '/sys/class/kgsl/kgsl-3d0/devfreq/governor',
        powerLevels: 8,
      ),
    );

PerfControlCapabilities _caps() => const PerfControlCapabilities(
      nodeAvailability: <String, bool>{
        '/sys/devices/system/cpu/cpufreq/policy0/scaling_governor': true,
        '/sys/class/thermal/thermal_zone0/mode': false,
      },
      binderLevers: <String, bool>{PerfControlLevers.settings: true},
      categoryAvailability: <PerfControlCategory, bool>{
        PerfControlCategory.cpu: true,
        PerfControlCategory.gpu: false,
        PerfControlCategory.cpuset: false,
        PerfControlCategory.thermal: false,
        PerfControlCategory.binderLevers: true,
      },
      nodeCounts: <PerfControlCategory, int>{PerfControlCategory.cpu: 1},
      timeoutAvailable: true,
      probedAtMs: 1729000000000,
    );

/// 构造被测工具模块（依赖全部注入；不触碰 Shizuku / 原生模块）。
AgentToolModule _tool({
  Future<TunablesReport> Function()? tunablesLoader,
  PerfTunablesCapabilitiesLoader? capabilitiesLoader,
  Duration timeout = kPerfTunablesToolTimeout,
}) =>
    PerfTunablesTools(
      tunablesLoader: tunablesLoader ?? () async => _tunables(),
      capabilitiesLoader: capabilitiesLoader ?? (t) async => _caps(),
      timeout: timeout,
    ).tools.single;

Map<String, dynamic> _decode(String text) =>
    jsonDecode(text) as Map<String, dynamic>;

Future<Map<String, dynamic>> _call(
  AgentToolModule tool, [
  Map<String, dynamic> params = const <String, dynamic>{},
]) async =>
    _decode(await tool.execute(const AgentToolContext(), params));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('元数据（工具模块协议）', () {
    test('toolName=perfTunables、moduleName、enabled、无参数、只读描述完整', () {
      final tool = _tool();
      expect(tool.toolName, 'perfTunables');
      expect(tool.moduleName, 'agent_tool_perfTunables');
      expect(tool.enabled, isTrue);
      expect(tool.toolParams, isEmpty);
      expect(tool.toolDescription.trim(), isNotEmpty);
    });
  });

  group('perfTunables 成功路径', () {
    test('返回结构化 tunables（CPU/cpuset/热区/散热/GPU）+ 能力图', () async {
      final json = await _call(_tool());
      expect(json['available'], isTrue);
      expect(json['capabilities_available'], isTrue);

      final tunables = json['tunables'] as Map<String, dynamic>;
      final clusters =
          (tunables['cpu_clusters'] as List).cast<Map<String, dynamic>>();
      expect(clusters.length, 1);
      expect(clusters.first['policy'], 'policy0');
      expect(clusters.first['governor'], 'schedutil');
      expect(clusters.first['available_frequencies_mhz'], <dynamic>[300, 1800]);

      final cpusets = (tunables['cpusets'] as List).cast<Map<String, dynamic>>();
      expect(cpusets.first['name'], 'top-app');

      final zones =
          (tunables['thermal_zones'] as List).cast<Map<String, dynamic>>();
      expect(zones.first['zone'], 'thermal_zone0');

      final cooling =
          (tunables['cooling_devices'] as List).cast<Map<String, dynamic>>();
      expect(cooling.first['device'], 'cooling_device0');

      final gpu = tunables['gpu'] as Map<String, dynamic>;
      expect(gpu['available_frequencies_mhz'], <dynamic>[200, 600]);
      expect(gpu['power_levels'], 8);

      final caps = json['capabilities'] as Map<String, dynamic>;
      expect(caps['timeout_available'], isTrue);
      final cats = caps['categories'] as Map<String, dynamic>;
      expect((cats['cpu'] as Map)['available'], isTrue);
      expect((cats['gpu'] as Map)['available'], isFalse);
    });

    test('无参数调用也返回 available（只读，无副作用）', () async {
      final json = await _call(_tool());
      expect(json['available'], isTrue);
    });
  });

  group('优雅降级（绝不抛出）', () {
    test('模块不可用：available=false + 结构化 message', () async {
      final json = await _call(
        _tool(tunablesLoader: () async => throw PerfModuleUnavailableException()),
      );
      expect(json['available'], isFalse);
      expect(json['error'], 'perf_module_unavailable');
      expect(json['message'], contains('未安装'));
    });

    test('加载抛任意异常：降级为结构化 unavailable，不抛出', () async {
      final json = await _call(
        _tool(tunablesLoader: () async => throw StateError('boom')),
      );
      expect(json['available'], isFalse);
      expect(json['error'], 'perf_module_unavailable');
    });

    test('能力探测抛异常：tunables 仍返回，能力标记为不可用', () async {
      final json = await _call(
        _tool(capabilitiesLoader: (t) async => throw StateError('no shizuku')),
      );
      expect(json['available'], isTrue);
      expect(json['capabilities_available'], isFalse);
      expect(json['capabilities'], isNull);
      expect(json['capabilities_message'], contains('fail-closed'));
    });

    test('能力探测返回 null（未探测）：capabilities_available=false', () async {
      final json = await _call(_tool(capabilitiesLoader: (t) async => null));
      expect(json['available'], isTrue);
      expect(json['capabilities_available'], isFalse);
      expect(json['capabilities_message'], isNotNull);
    });

    test('加载挂起 → 有界超时（error=timeout，不抛出）', () async {
      final json = await _call(
        _tool(
          tunablesLoader: () async {
            await Future<void>.delayed(const Duration(milliseconds: 300));
            return _tunables();
          },
          timeout: const Duration(milliseconds: 30),
        ),
      );
      expect(json['available'], isFalse);
      expect(json['error'], 'timeout');
    });
  });

  group('context.cancelled → 直接返回「已取消」', () {
    test('stopRequested 为真时不执行任何读取', () async {
      final tool = _tool();
      final result = await tool.execute(
        AgentToolContext(stopRequested: () => true),
        const <String, dynamic>{},
      );
      expect(result, '已取消');
    });
  });

  group('注册到 AgentToolsModule.tools（AgentService 实际消费集合）', () {
    test('包含只读 perfTunables + 危险门控 perfControl，且无重复 toolName', () {
      final names = AgentToolsModule().tools.map((t) => t.toolName).toList();
      expect(
        names,
        containsAll(<String>[
          'perfTunables',
          'perfControl',
          'perfDeviceSnapshot',
          'perfThirdPartyMetrics',
          'perfFrameStats',
        ]),
        reason: 'AgentService 仅从 AgentToolsModule.tools 拉取工具',
      );
      expect(names.toSet().length, names.length,
          reason: '注册集合不得含重复 toolName');
    });

    test('注册的 perfControl 无 confirm → 结构化拒绝（门禁先于任何命令）', () async {
      final control =
          AgentToolsModule().tools.firstWhere((t) => t.toolName == 'perfControl');
      final json = _decode(
        await control.execute(const AgentToolContext(), <String, dynamic>{
          'action': 'thermal',
          'enabled': false,
        }),
      );
      expect(json['ok'], isFalse);
      expect(json['error'], PerfControlError.confirmRequired);
    });
  });
}
