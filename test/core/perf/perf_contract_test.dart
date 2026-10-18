import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/rust/perf/PerfContract.dart';
import 'package:gstore/core/rust/perf/PerfModule.dart';

/// 假网关：受控返回信封响应 + 可推送原始事件；**不触碰 FFI**。
class _FakeGateway implements PerfModuleGateway {
  _FakeGateway(this.responses);

  final Map<String, Uint8List> responses;
  final StreamController<PerfRawEvent> controller =
      StreamController<PerfRawEvent>.broadcast();
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
  Stream<PerfRawEvent> get events => controller.stream;
}

/// 成功信封 `{ok:true,data:{...}}`。
Uint8List _okEnvelope(Map<String, dynamic> data) => Uint8List.fromList(
      utf8.encode(jsonEncode(<String, dynamic>{'ok': true, 'data': data})),
    );

Uint8List _eventJson(Map<String, dynamic> data) =>
    Uint8List.fromList(utf8.encode(jsonEncode(data)));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CpuReport (README perf.cpu)', () {
    test('decodes full schema incl. null frequency placeholder', () {
      final report = CpuReport.fromJson(<String, dynamic>{
        'usage_percent': 37.5,
        'per_core_usage': <dynamic>[10.0, 20.5, 30],
        'core_count': 3,
        'frequencies_mhz': <dynamic>[1800.0, null, 2400.0],
        'governor': 'schedutil',
        'available_frequencies_mhz': <dynamic>[300.0, 1800.0, 2400.0],
        'max_freq_mhz': 2400.0,
        'min_freq_mhz': 300.0,
        'loadavg': <String, dynamic>{
          'load1': 0.15,
          'load5': 0.10,
          'load15': 0.05,
          'runnable': 1,
          'total': 234,
          'last_pid': 5678,
        },
        'cores': <dynamic>[
          <String, dynamic>{'id': 0, 'freq_mhz': 1800.0},
          <String, dynamic>{'id': 1, 'freq_mhz': null},
        ],
      });

      expect(report.usagePercent, 37.5);
      expect(report.perCoreUsage, <double>[10.0, 20.5, 30.0]);
      expect(report.coreCount, 3);
      expect(report.frequenciesMhz, <double?>[1800.0, null, 2400.0]);
      expect(report.governor, 'schedutil');
      expect(report.availableFrequenciesMhz, <double>[300.0, 1800.0, 2400.0]);
      expect(report.maxFreqMhz, 2400.0);
      expect(report.minFreqMhz, 300.0);
      expect(report.loadavg?.load1, 0.15);
      expect(report.loadavg?.lastPid, 5678);
      expect(report.cores.length, 2);
      expect(report.cores[0].freqMhz, 1800.0);
      expect(report.cores[1].freqMhz, isNull);
    });

    test('tolerates missing fields and numeric strings', () {
      final empty = CpuReport.fromJson(const <String, dynamic>{});
      expect(empty.usagePercent, 0);
      expect(empty.perCoreUsage, isEmpty);
      expect(empty.governor, isNull);
      expect(empty.loadavg, isNull);

      final coerced = CpuReport.fromJson(<String, dynamic>{
        'usage_percent': '42.5',
        'core_count': '4',
      });
      expect(coerced.usagePercent, 42.5);
      expect(coerced.coreCount, 4);
    });
  });

  group('MemoryReport (README perf.memory)', () {
    test('decodes KiB fields and human strings', () {
      final report = MemoryReport.fromJson(<String, dynamic>{
        'total_kb': 16384000,
        'free_kb': 2048000,
        'available_kb': 8192000,
        'buffers_kb': 512000,
        'cached_kb': 4096000,
        'sreclaimable_kb': 256000,
        'shmem_kb': 128000,
        'slab_kb': 384000,
        'used_kb': 8192000,
        'used_percent': 50.0,
        'swap_total_kb': 4096000,
        'swap_free_kb': 3072000,
        'swap_used_kb': 1024000,
        'swap_percent': 25.0,
        'swap_cached_kb': 16000,
        'dirty_kb': 32000,
        'zram_total_kb': 2048000,
        'zram_used_kb': 512000,
        'total_human': '15.62 GB',
        'used_human': '7.81 GB',
        'available_human': '7.81 GB',
        'swap_total_human': '3.91 GB',
        'swap_used_human': '1000.00 MB',
      });

      expect(report.totalKb, 16384000);
      expect(report.availableKb, 8192000);
      expect(report.usedKb, 8192000);
      expect(report.usedPercent, 50.0);
      expect(report.swapUsedKb, 1024000);
      expect(report.swapPercent, 25.0);
      expect(report.zramUsedKb, 512000);
      expect(report.totalHuman, '15.62 GB');
      expect(report.swapUsedHuman, '1000.00 MB');
    });

    test('empty memory is all zeros', () {
      final report = MemoryReport.fromJson(const <String, dynamic>{});
      expect(report.totalKb, 0);
      expect(report.usedPercent, 0);
      expect(report.totalHuman, '');
    });
  });

  group('BatteryReport (README perf.battery)', () {
    test('decodes present battery', () {
      final report = BatteryReport.fromJson(<String, dynamic>{
        'present': true,
        'base_path': '/sys/class/power_supply/battery',
        'capacity_percent': 76.0,
        'voltage_v': 3.8,
        'current_ma': -550.0,
        'temperature_c': 32.9,
        'status': 'Discharging',
        'health': 'Good',
        'technology': 'Li-ion',
        'charge_full_uah': 4400000,
        'charge_full_design_uah': 4000000,
        'cycle_count': 123,
      });

      expect(report.present, isTrue);
      expect(report.basePath, '/sys/class/power_supply/battery');
      expect(report.capacityPercent, 76.0);
      expect(report.voltageV, 3.8);
      expect(report.currentMa, -550.0);
      expect(report.temperatureC, 32.9);
      expect(report.status, 'Discharging');
      expect(report.cycleCount, 123);
    });

    test('absent battery keeps optional fields null', () {
      final report = BatteryReport.fromJson(<String, dynamic>{
        'present': false,
        'base_path': null,
        'capacity_percent': null,
      });
      expect(report.present, isFalse);
      expect(report.basePath, isNull);
      expect(report.capacityPercent, isNull);
      expect(report.currentMa, isNull);
    });
  });

  group('ThermalReport (README perf.thermal)', () {
    test('decodes zones and max temp', () {
      final report = ThermalReport.fromJson(<String, dynamic>{
        'zone_count': 2,
        'max_temp_c': 61.5,
        'zones': <dynamic>[
          <String, dynamic>{
            'source': 'thermal_zone',
            'zone': 'thermal_zone0',
            'kind': 'cpu',
            'temp_c': 61.5,
          },
          <String, dynamic>{
            'source': 'hwmon',
            'zone': 'hwmon3/temp1_input',
            'kind': null,
            'temp_c': 40.0,
          },
        ],
      });

      expect(report.zoneCount, 2);
      expect(report.maxTempC, 61.5);
      expect(report.zones.length, 2);
      expect(report.zones[0].source, 'thermal_zone');
      expect(report.zones[0].kind, 'cpu');
      expect(report.zones[1].kind, isNull);
      expect(report.zones[1].tempC, 40.0);
    });

    test('empty thermal report', () {
      final report = ThermalReport.fromJson(const <String, dynamic>{});
      expect(report.zoneCount, 0);
      expect(report.maxTempC, isNull);
      expect(report.zones, isEmpty);
    });
  });

  group('GpuReport (README perf.gpu)', () {
    test('decodes present gpu fields', () {
      final report = GpuReport.fromJson(<String, dynamic>{
        'name': 'Adreno 660',
        'freq_mhz': 800.0,
        'freq_source': '/sys/class/kgsl/kgsl-3d0/gpuclk',
        'busy_percent': 42.0,
        'busy_source': '/sys/class/kgsl/kgsl-3d0/gpu_busy_percentage',
      });

      expect(report.name, 'Adreno 660');
      expect(report.freqMhz, 800.0);
      expect(report.busyPercent, 42.0);
      expect(report.freqSource, contains('gpuclk'));
    });

    test('absent gpu is all null', () {
      final report = GpuReport.fromJson(const <String, dynamic>{});
      expect(report.name, isNull);
      expect(report.freqMhz, isNull);
      expect(report.busyPercent, isNull);
    });
  });

  group('NetworkReport (README perf.network)', () {
    test('decodes totals and interfaces', () {
      final report = NetworkReport.fromJson(<String, dynamic>{
        'rx_bytes': 501000,
        'tx_bytes': 802000,
        'rx_bytes_per_sec': 1000.0,
        'tx_bytes_per_sec': 2000.0,
        'interfaces': <dynamic>[
          <String, dynamic>{
            'name': 'wlan0',
            'rx_bytes': 500000,
            'tx_bytes': 800000,
            'rx_packets': 400,
            'tx_packets': 500,
            'rx_bytes_per_sec': 1000.0,
            'tx_bytes_per_sec': 2000.0,
          },
        ],
      });

      expect(report.rxBytes, 501000);
      expect(report.txBytes, 802000);
      expect(report.rxBytesPerSec, 1000.0);
      expect(report.interfaces.length, 1);
      expect(report.interfaces[0].name, 'wlan0');
      expect(report.interfaces[0].txBytesPerSec, 2000.0);
    });

    test('missing interfaces defaults to empty', () {
      final report = NetworkReport.fromJson(const <String, dynamic>{});
      expect(report.interfaces, isEmpty);
      expect(report.rxBytes, 0);
    });
  });

  group('ProcessReport (README perf.processes)', () {
    test('decodes total/sort/processes', () {
      final report = ProcessReport.fromJson(<String, dynamic>{
        'total': 234,
        'sort': 'rss',
        'processes': <dynamic>[
          <String, dynamic>{
            'pid': 1234,
            'name': 'Web Content',
            'cmdline': 'com.foo.app --flag x',
            'state': 'S',
            'cpu_ticks': 200,
            'cpu_percent': 12.5,
            'rss_kb': 204800,
            'rss_bytes': 209715200,
          },
          <String, dynamic>{
            'pid': 1,
            'name': 'init',
            'cmdline': null,
            'state': 'S',
            'cpu_ticks': 10,
            'cpu_percent': 0.0,
            'rss_kb': 1024,
            'rss_bytes': 1048576,
          },
        ],
      });

      expect(report.total, 234);
      expect(report.sort, 'rss');
      expect(report.processes.length, 2);
      expect(report.processes[0].pid, 1234);
      expect(report.processes[0].name, 'Web Content');
      expect(report.processes[0].cmdline, 'com.foo.app --flag x');
      expect(report.processes[0].cpuPercent, 12.5);
      expect(report.processes[1].cmdline, isNull);
    });

    test('defaults sort to cpu when absent', () {
      final report = ProcessReport.fromJson(const <String, dynamic>{});
      expect(report.sort, 'cpu');
      expect(report.processes, isEmpty);
    });
  });

  group('DeviceReport (README perf.device)', () {
    test('decodes identity fields', () {
      final report = DeviceReport.fromJson(<String, dynamic>{
        'kernel_version': 'Linux version 5.10.43',
        'hardware': 'Qualcomm Technologies, Inc SM8350',
        'cpu_name': '高通骁龙处理器',
        'model': 'Pixel 6',
        'android_release': '14',
        'board_platform': 'sm8350',
        'core_count': 8,
        'loadavg': <String, dynamic>{
          'load1': 1.0,
          'load5': 1.5,
          'load15': 2.0,
          'runnable': 3,
          'total': 800,
          'last_pid': 999,
        },
        'os_release': 'Android 14',
      });

      expect(report.kernelVersion, startsWith('Linux version'));
      expect(report.cpuName, '高通骁龙处理器');
      expect(report.model, 'Pixel 6');
      expect(report.androidRelease, '14');
      expect(report.coreCount, 8);
      expect(report.loadavg?.load15, 2.0);
      expect(report.osRelease, 'Android 14');
    });
  });

  group('PerfSnapshot', () {
    final snapshotJson = <String, dynamic>{
      'ts_ms': 1729000000000,
      'cpu': <String, dynamic>{'usage_percent': 10.0, 'core_count': 2},
      'memory': <String, dynamic>{'total_kb': 1000, 'used_kb': 400},
      'battery': <String, dynamic>{'present': true, 'capacity_percent': 80.0},
      'thermal': <String, dynamic>{'zone_count': 1, 'max_temp_c': 40.0},
      'gpu': <String, dynamic>{'name': 'Adreno'},
      'network': <String, dynamic>{'rx_bytes': 10, 'tx_bytes': 20},
      'device': <String, dynamic>{'model': 'Pixel'},
    };

    test('decodes all sections', () {
      final snapshot = PerfSnapshot.fromJson(snapshotJson);
      expect(snapshot.tsMs, 1729000000000);
      expect(snapshot.cpu?.usagePercent, 10.0);
      expect(snapshot.memory?.totalKb, 1000);
      expect(snapshot.battery?.present, isTrue);
      expect(snapshot.thermal?.maxTempC, 40.0);
      expect(snapshot.gpu?.name, 'Adreno');
      expect(snapshot.network?.txBytes, 20);
      expect(snapshot.device?.model, 'Pixel');
      expect(snapshot.processes, isNull);
    });

    test('empty snapshot keeps all sections null', () {
      final snapshot = PerfSnapshot.fromJson(const <String, dynamic>{});
      expect(snapshot.tsMs, 0);
      expect(snapshot.cpu, isNull);
      expect(snapshot.memory, isNull);
      expect(snapshot.battery, isNull);
      expect(snapshot.processes, isNull);
    });
  });

  group('PerfSample / PerfHistory', () {
    test('event payload decodes as a sample without seq', () {
      final sample = PerfSample.fromEventJson(<String, dynamic>{
        'ts_ms': 42,
        'cpu': <String, dynamic>{'usage_percent': 5.0},
      });
      expect(sample.seq, isNull);
      expect(sample.tsMs, 42);
      expect(sample.snapshot.cpu?.usagePercent, 5.0);
    });

    test('history entry decodes documented seq and wraps data', () {
      final sample = PerfSample.fromHistoryEntry(<String, dynamic>{
        'seq': 7,
        'ts_ms': 99,
        'data': <String, dynamic>{
          'ts_ms': 98,
          'memory': <String, dynamic>{'used_percent': 55.0},
        },
      });
      expect(sample.seq, 7);
      // ts 取自 `data` 内的快照（README：data 即快照 JSON）。
      expect(sample.tsMs, 98);
      expect(sample.snapshot.memory?.usedPercent, 55.0);
    });

    test('PerfHistory decodes ring metadata and samples', () {
      final history = PerfHistory.fromJson(<String, dynamic>{
        'count': 2,
        'capacity': 300,
        'samples': <dynamic>[
          <String, dynamic>{'seq': 1, 'ts_ms': 1, 'data': <String, dynamic>{}},
          <String, dynamic>{'seq': 2, 'ts_ms': 2, 'data': <String, dynamic>{}},
        ],
      });

      expect(history.count, 2);
      expect(history.capacity, 300);
      expect(history.samples.length, 2);
      expect(history.samples[0].seq, 1);
      expect(history.samples[1].seq, 2);
    });

    test('PerfHistory tolerates missing samples', () {
      final history = PerfHistory.fromJson(const <String, dynamic>{});
      expect(history.count, 0);
      expect(history.capacity, 0);
      expect(history.samples, isEmpty);
    });
  });

  group('PerfModule facade', () {
    test('processes encodes payload and decodes typed report', () async {
      final gateway = _FakeGateway(<String, Uint8List>{
        PerfMethods.processes: _okEnvelope(<String, dynamic>{
          'total': 1,
          'sort': 'cpu',
          'processes': <dynamic>[
            <String, dynamic>{
              'pid': 42,
              'name': 'gstore',
              'cpu_percent': 3.5,
              'rss_kb': 100,
              'rss_bytes': 102400,
            },
          ],
        }),
      });
      final facade = PerfModule(gateway: gateway);

      final report = await facade.processes(limit: 5, sort: 'cpu');

      expect(report.total, 1);
      expect(report.processes.single.pid, 42);
      expect(gateway.methods, <String>[PerfMethods.processes]);
      final payload = jsonDecode(utf8.decode(gateway.payloads.single))
          as Map<String, dynamic>;
      expect(payload['limit'], 5);
      expect(payload['sort'], 'cpu');
    });

    test('startSampling forwards interval and decodes result', () async {
      final gateway = _FakeGateway(<String, Uint8List>{
        PerfMethods.start: _okEnvelope(<String, dynamic>{
          'running': true,
          'interval_ms': 2000,
          'instanceId': 9,
        }),
      });
      final facade = PerfModule(gateway: gateway);

      final result = await facade.startSampling(intervalMs: 2000);

      expect(result.running, isTrue);
      expect(result.intervalMs, 2000);
      expect(result.instanceId, 9);
    });

    test('error envelope maps to PerfModuleException', () async {
      final gateway = _FakeGateway(<String, Uint8List>{
        PerfMethods.ping: Uint8List.fromList(utf8.encode(jsonEncode(
          <String, dynamic>{
            'status': 404,
            'code': 'METHOD_NOT_FOUND',
            'message': 'nope',
          },
        ))),
      });
      final facade = PerfModule(gateway: gateway);

      expect(
        facade.ping(),
        throwsA(
          isA<PerfModuleException>()
              .having((e) => e.code, 'code', 'METHOD_NOT_FOUND')
              .having((e) => e.status, 'status', 404),
        ),
      );
    });

    test('perf.sample event stream decodes to PerfSample', () async {
      final gateway = _FakeGateway(const <String, Uint8List>{});
      final facade = PerfModule(gateway: gateway);

      final pending = facade.samples.first;
      gateway.controller.add(PerfRawEvent(
        eventType: PerfEvents.sample,
        data: _eventJson(<String, dynamic>{
          'ts_ms': 123,
          'cpu': <String, dynamic>{'usage_percent': 12.5},
          'memory': <String, dynamic>{'used_percent': 60.0},
        }),
      ));

      final sample = await pending;
      expect(sample.tsMs, 123);
      expect(sample.snapshot.cpu?.usagePercent, 12.5);
      expect(sample.snapshot.memory?.usedPercent, 60.0);

      await gateway.controller.close();
    });
  });
}
