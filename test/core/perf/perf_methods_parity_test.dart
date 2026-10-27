// Rust ↔ Dart 方法表「无序集合」一致性 + 新增模型宽容解码 + 门面包装测试。
//
// 先例（precedent）：`test/proxy_contract_test.dart:985-999` 从 Rust `DISPATCH_METHODS`
// 解析方法名集并做集合断言。**差异**：perf 的锚点是 `pub const DISPATCH_METHODS`
// （proxy 为 `pub(crate) const`），且此处断言**无序集合相等**（双向差集为空），
// **不是**有序列表相等 —— 两侧顺序本就不同。
//
// 该测试是防止「只改 Dart 契约 / 漏 Rust arm」（或反向）的硬闸门。
import 'dart:convert';
import 'dart:typed_data';

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/rust/perf/PerfContract.dart';
import 'package:gstore/core/rust/perf/PerfModule.dart';

/// 假网关：受控返回信封响应；**不触碰 FFI**。
class _FakeGateway implements PerfModuleGateway {
  _FakeGateway(this.responses);

  final Map<String, Uint8List> responses;
  final List<String> methods = <String>[];
  final List<Uint8List> payloads = <Uint8List>[];

  @override
  Future<Uint8List> call(String method, [Uint8List? payload]) async {
    methods.add(method);
    payloads.add(payload ?? Uint8List(0));
    final response = responses[method];
    if (response == null) {
      throw StateError('no stub for $method');
    }
    return response;
  }

  @override
  Stream<PerfRawEvent> get events => const Stream<PerfRawEvent>.empty();
}

/// 成功信封 `{ok:true,data:{...}}`。
Uint8List _okEnvelope(Map<String, dynamic> data) => Uint8List.fromList(
      utf8.encode(jsonEncode(<String, dynamic>{'ok': true, 'data': data})),
    );

/// 从 Rust `src/methods.rs` 的 `DISPATCH_METHODS` 常量块解析出真正被 `dispatch`
/// 的方法集。锚点为 perf 专用的 `pub const DISPATCH_METHODS`（**非** proxy 的
/// `pub(crate) const`）。
Set<String> _rustDispatchMethods(String rustSrc) {
  final start = rustSrc.indexOf('pub const DISPATCH_METHODS');
  expect(start, isNonNegative, reason: 'methods.rs 必须定义 pub const DISPATCH_METHODS');
  final open = rustSrc.indexOf('&[', start);
  final end = rustSrc.indexOf('];', open);
  expect(open, isNonNegative);
  expect(end, greaterThan(open));
  final block = rustSrc.substring(open, end);
  // 块内只含方法名字符串：`ping` 无点，其余为点分。
  final re = RegExp(r'"([a-z][a-z0-9_]*(?:\.[a-z0-9_]+)*)"');
  return <String>{for (final m in re.allMatches(block)) m.group(1)!};
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DISPATCH_METHODS ↔ PerfMethods.all（无序集合相等）', () {
    test('双向差集皆空（任一侧漏改即红）', () {
      final rustSrc =
          File('rust/gstore_mod_perf/src/methods.rs').readAsStringSync();
      final dispatch = _rustDispatchMethods(rustSrc);
      final dartMethods = PerfMethods.all.toSet();

      expect(dispatch, isNotEmpty, reason: 'DISPATCH_METHODS 必须可解析且非空');
      expect(dartMethods, hasLength(25), reason: 'Dart 契约现应为 25 个方法');
      expect(dispatch, hasLength(25), reason: 'Rust DISPATCH_METHODS 现应为 25 个方法');

      // 无序集合相等：双向差集皆空（**不是**有序相等——两侧顺序本就不同）。
      final rustOnly = dispatch.difference(dartMethods);
      final dartOnly = dartMethods.difference(dispatch);
      expect(rustOnly, isEmpty,
          reason: 'Rust DISPATCH_METHODS 有但 Dart PerfMethods.all 缺失: $rustOnly');
      expect(dartOnly, isEmpty,
          reason: 'Dart PerfMethods.all 有但 Rust DISPATCH_METHODS 缺失: $dartOnly');
    });

    test('新增三个方法常量在表内且字面量正确', () {
      expect(PerfMethods.tunables, 'perf.tunables');
      expect(PerfMethods.sysfsRead, 'perf.sysfs.read');
      expect(PerfMethods.foreground, 'perf.foreground');
      expect(
        PerfMethods.all,
        containsAll(<String>[
          'perf.tunables',
          'perf.sysfs.read',
          'perf.foreground',
        ]),
      );
    });
  });

  group('TunablesReport (README perf.tunables)', () {
    test('decodes full schema incl. nested arrays and gpu', () {
      final report = TunablesReport.fromJson(<String, dynamic>{
        'cpu_clusters': <dynamic>[
          <String, dynamic>{
            'policy': 'policy0',
            'related_cpus': <dynamic>[0, 1, 2, 3],
            'available_governors': <dynamic>['schedutil', 'performance'],
            'governor': 'schedutil',
            'available_frequencies_mhz': <dynamic>[300.0, 1800.0, 2400.0],
            'min_freq_mhz': 300.0,
            'max_freq_mhz': 2400.0,
          },
        ],
        'cpusets': <dynamic>[
          <String, dynamic>{'name': 'top-app', 'cpus': '0-7', 'mems': '0'},
          <String, dynamic>{'name': 'background', 'cpus': null, 'mems': null},
        ],
        'thermal_zones': <dynamic>[
          <String, dynamic>{
            'zone': 'thermal_zone0',
            'type': 'cpu-0-0-0',
            'mode': 'enabled',
          },
        ],
        'cooling_devices': <dynamic>[
          <String, dynamic>{
            'device': 'cooling_device0',
            'type': 'cpu',
            'cur_state': 1,
            'max_state': 10,
          },
        ],
        'gpu': <String, dynamic>{
          'available_frequencies_mhz': <dynamic>[500.0, 800.0],
          'freq_source': '/sys/class/kgsl/kgsl-3d0/devfreq/available_frequencies',
          'governor': 'msm-adreno-tz',
          'governor_source': '/sys/class/kgsl/kgsl-3d0/devfreq/governor',
          'power_levels': 14,
          'power_source': '/sys/class/kgsl/kgsl-3d0/num_pwrlevels',
        },
      });

      expect(report.cpuClusters.length, 1);
      expect(report.cpuClusters[0].policy, 'policy0');
      expect(report.cpuClusters[0].relatedCpus, <int>[0, 1, 2, 3]);
      expect(report.cpuClusters[0].governor, 'schedutil');
      expect(report.cpuClusters[0].availableFrequenciesMhz,
          <double>[300.0, 1800.0, 2400.0]);
      expect(report.cpuClusters[0].maxFreqMhz, 2400.0);

      expect(report.cpusets.length, 2);
      expect(report.cpusets[0].cpus, '0-7');
      expect(report.cpusets[1].cpus, isNull);

      expect(report.thermalZones.single.zone, 'thermal_zone0');
      expect(report.thermalZones.single.type, 'cpu-0-0-0');
      expect(report.thermalZones.single.mode, 'enabled');

      expect(report.coolingDevices.single.device, 'cooling_device0');
      expect(report.coolingDevices.single.curState, 1);
      expect(report.coolingDevices.single.maxState, 10);

      expect(report.gpu.availableFrequenciesMhz, <double>[500.0, 800.0]);
      expect(report.gpu.governor, 'msm-adreno-tz');
      expect(report.gpu.powerLevels, 14);
      expect(report.gpu.freqSource, contains('available_frequencies'));
    });

    test('empty / node-less report → empty arrays + default gpu (never throws)',
        () {
      final report = TunablesReport.fromJson(const <String, dynamic>{});
      expect(report.cpuClusters, isEmpty);
      expect(report.cpusets, isEmpty);
      expect(report.thermalZones, isEmpty);
      expect(report.coolingDevices, isEmpty);
      expect(report.gpu.availableFrequenciesMhz, isEmpty);
      expect(report.gpu.governor, isNull);
      expect(report.gpu.powerLevels, isNull);

      // null gpu / null sub-objects / null members 一律宽容。
      final nulled = TunablesReport.fromJson(<String, dynamic>{
        'gpu': null,
        'cpu_clusters': <dynamic>[null, 42, <String, dynamic>{}],
      });
      expect(nulled.gpu.governor, isNull);
      expect(nulled.cpuClusters.length, 1);
      expect(nulled.cpuClusters.single.policy, '');
    });

    test('non-finite numbers are dropped, never decoded as NaN', () {
      final report = TunablesReport.fromJson(<String, dynamic>{
        'cpu_clusters': <dynamic>[
          <String, dynamic>{
            'policy': 'policy0',
            'available_frequencies_mhz': <dynamic>['800', 'NaN', 1000, 'Infinity'],
            'min_freq_mhz': 'NaN',
            'max_freq_mhz': 'Infinity',
          },
        ],
        'gpu': <String, dynamic>{
          'available_frequencies_mhz': <dynamic>[double.nan, 585.0, double.infinity],
        },
      });

      final cluster = report.cpuClusters.single;
      expect(cluster.availableFrequenciesMhz, <double>[800.0, 1000.0]);
      expect(cluster.availableFrequenciesMhz.any((v) => v.isNaN), isFalse);
      expect(cluster.minFreqMhz, isNull);
      expect(cluster.maxFreqMhz, isNull);
      expect(report.gpu.availableFrequenciesMhz, <double>[585.0]);
      expect(report.gpu.availableFrequenciesMhz.any((v) => v.isNaN), isFalse);
    });
  });

  group('SysfsReadResult (README perf.sysfs.read)', () {
    test('decodes value and exists', () {
      final ok = SysfsReadResult.fromJson(<String, dynamic>{
        'path': '/sys/class/thermal/thermal_zone0/temp',
        'value': '27800',
        'exists': true,
      });
      expect(ok.path, '/sys/class/thermal/thermal_zone0/temp');
      expect(ok.value, '27800');
      expect(ok.exists, isTrue);
    });

    test('absent node → value null, exists false (not an error)', () {
      final absent = SysfsReadResult.fromJson(<String, dynamic>{
        'path': '/sys/class/thermal/thermal_zone9/temp',
        'value': null,
        'exists': false,
      });
      expect(absent.value, isNull);
      expect(absent.exists, isFalse);

      final empty = SysfsReadResult.fromJson(const <String, dynamic>{});
      expect(empty.path, '');
      expect(empty.value, isNull);
      expect(empty.exists, isFalse);
    });
  });

  group('ForegroundReport (README perf.foreground)', () {
    test('decodes package', () {
      final report = ForegroundReport.fromJson(<String, dynamic>{
        'package': 'com.example.app',
      });
      expect(report.package, 'com.example.app');
    });

    test('null / missing package stays null (never guesses)', () {
      final nullPkg = ForegroundReport.fromJson(<String, dynamic>{'package': null});
      expect(nullPkg.package, isNull);

      final empty = ForegroundReport.fromJson(const <String, dynamic>{});
      expect(empty.package, isNull);
    });
  });

  group('PerfModule facade (new wrappers)', () {
    test('tunables() calls perf.tunables and decodes typed report', () async {
      final gateway = _FakeGateway(<String, Uint8List>{
        PerfMethods.tunables: _okEnvelope(<String, dynamic>{
          'cpu_clusters': <dynamic>[
            <String, dynamic>{'policy': 'policy0', 'governor': 'schedutil'},
          ],
          'gpu': <String, dynamic>{'governor': 'msm-adreno-tz'},
        }),
      });
      final facade = PerfModule(gateway: gateway);

      final report = await facade.tunables();

      expect(gateway.methods, <String>[PerfMethods.tunables]);
      expect(report.cpuClusters.single.policy, 'policy0');
      expect(report.gpu.governor, 'msm-adreno-tz');
    });

    test('readSysfs() forwards {path} and decodes result', () async {
      final gateway = _FakeGateway(<String, Uint8List>{
        PerfMethods.sysfsRead: _okEnvelope(<String, dynamic>{
          'path': '/sys/devices/system/cpu/cpufreq/policy0/scaling_governor',
          'value': 'schedutil',
          'exists': true,
        }),
      });
      final facade = PerfModule(gateway: gateway);

      final result =
          await facade.readSysfs('/sys/devices/system/cpu/cpufreq/policy0/scaling_governor');

      expect(gateway.methods, <String>[PerfMethods.sysfsRead]);
      final payload =
          jsonDecode(utf8.decode(gateway.payloads.single)) as Map<String, dynamic>;
      expect(payload['path'],
          '/sys/devices/system/cpu/cpufreq/policy0/scaling_governor');
      expect(result.value, 'schedutil');
      expect(result.exists, isTrue);
    });

    test('foreground() forwards {activity} and decodes null package', () async {
      final gateway = _FakeGateway(<String, Uint8List>{
        PerfMethods.foreground: _okEnvelope(<String, dynamic>{'package': null}),
      });
      final facade = PerfModule(gateway: gateway);

      final report = await facade.foreground('no resumed line here');

      expect(gateway.methods, <String>[PerfMethods.foreground]);
      final payload =
          jsonDecode(utf8.decode(gateway.payloads.single)) as Map<String, dynamic>;
      expect(payload['activity'], 'no resumed line here');
      expect(report.package, isNull);
    });
  });
}
