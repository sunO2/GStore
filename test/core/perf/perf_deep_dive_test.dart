import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/rust/perf/PerfContract.dart';
import 'package:gstore/core/rust/perf/PerfModule.dart';

/// 假网关：受控返回信封响应；**不触碰 FFI**。
class _FakeGateway implements PerfModuleGateway {
  _FakeGateway(this.responses);

  final Map<String, Uint8List> responses;
  final List<String> methods = <String>[];

  @override
  Future<Uint8List> call(String method, [Uint8List? payload]) async {
    methods.add(method);
    final response = responses[method];
    if (response == null) {
      throw StateError('no stub for $method');
    }
    return response;
  }

  @override
  Stream<PerfRawEvent> get events => const Stream<PerfRawEvent>.empty();
}

Uint8List _okEnvelope(Map<String, dynamic> data) => Uint8List.fromList(
      utf8.encode(jsonEncode(<String, dynamic>{'ok': true, 'data': data})),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PerfMethods registry', () {
    test('注册表包含新增的深度报告方法', () {
      expect(PerfMethods.pressure, 'perf.pressure');
      expect(PerfMethods.cooling, 'perf.cooling');
      expect(PerfMethods.batteryHealth, 'perf.battery_health');
      expect(PerfMethods.storage, 'perf.storage');
      expect(PerfMethods.all, contains(PerfMethods.pressure));
      expect(PerfMethods.all, contains(PerfMethods.cooling));
      expect(PerfMethods.all, contains(PerfMethods.batteryHealth));
      expect(PerfMethods.all, contains(PerfMethods.storage));
    });
  });

  group('PerfPressureReport (perf.pressure)', () {
    test('解码 CPU / 内存 / IO 的 some 与 full', () {
      final report = PerfPressureReport.fromJson(<String, dynamic>{
        'cpu': <String, dynamic>{
          'some': <String, dynamic>{
            'avg10': 1.5,
            'avg60': 2.25,
            'avg300': 3.0,
            'total_us': 123456,
          },
          'full': <String, dynamic>{
            'avg10': 0.5,
            'avg60': 0.75,
            'avg300': 1.0,
            'total_us': 1000,
          },
        },
        'memory': <String, dynamic>{
          'some': <String, dynamic>{'avg10': 4.0, 'avg60': 5.0},
          'full': <String, dynamic>{'avg10': 0.1},
        },
        'io': <String, dynamic>{
          'some': <String, dynamic>{'avg10': 9.9},
        },
      });

      expect(report.cpuSome?.avg10, 1.5);
      expect(report.cpuSome?.avg60, 2.25);
      expect(report.cpuSome?.totalUs, 123456);
      expect(report.cpuFull?.avg10, 0.5);
      expect(report.memorySome?.avg10, 4.0);
      expect(report.memoryFull?.avg10, 0.1);
      expect(report.ioSome?.avg10, 9.9);
      expect(report.ioFull, isNull);
    });

    test('缺失 / 空对象宽容为 null', () {
      final empty = PerfPressureReport.fromJson(const <String, dynamic>{});
      expect(empty.cpuSome, isNull);
      expect(empty.memorySome, isNull);
      expect(empty.ioSome, isNull);

      final partial = PerfPressureReport.fromJson(<String, dynamic>{
        'cpu': <String, dynamic>{},
      });
      expect(partial.cpuSome, isNull);
      expect(partial.cpuFull, isNull);
    });

    test('数值字符串宽容解码', () {
      final sample = PerfPressureSample.fromJson(<String, dynamic>{
        'avg10': '7.5',
        'total_us': '42',
      });
      expect(sample.avg10, 7.5);
      expect(sample.totalUs, 42);
    });
  });

  group('PerfCoolingReport (perf.cooling)', () {
    test('解码设备列表', () {
      final report = PerfCoolingReport.fromJson(<String, dynamic>{
        'count': 2,
        'devices': <dynamic>[
          <String, dynamic>{
            'device': 'cooling_device0',
            'type': 'cpu',
            'cur_state': 3,
            'max_state': 10,
          },
          <String, dynamic>{
            'device': 'cooling_device1',
            'type': 'battery',
            'cur_state': 0,
            'max_state': 4,
          },
        ],
      });

      expect(report.count, 2);
      expect(report.devices.length, 2);
      expect(report.devices[0].device, 'cooling_device0');
      expect(report.devices[0].type, 'cpu');
      expect(report.devices[0].curState, 3);
      expect(report.devices[0].maxState, 10);
      expect(report.devices[1].type, 'battery');
    });

    test('缺失字段宽容为空列表 / 零', () {
      final report = PerfCoolingReport.fromJson(const <String, dynamic>{});
      expect(report.count, 0);
      expect(report.devices, isEmpty);
    });
  });

  group('PerfBatteryHealthReport (perf.battery_health)', () {
    test('解码完整电池健康', () {
      final report = PerfBatteryHealthReport.fromJson(<String, dynamic>{
        'present': true,
        'base_path': '/sys/class/power_supply/battery',
        'charge_full_uah': 4400000,
        'charge_full_design_uah': 4000000,
        'cycle_count': 321,
        'health': 'Good',
        'status': 'Discharging',
        'technology': 'Li-ion',
        'charge_counter_uah': 3300000,
        'capacity_percent': 76.0,
        'voltage_v': 3.82,
        'temperature_c': 31.5,
      });

      expect(report.present, isTrue);
      expect(report.chargeFullUah, 4400000);
      expect(report.chargeFullDesignUah, 4000000);
      expect(report.cycleCount, 321);
      expect(report.health, 'Good');
      expect(report.status, 'Discharging');
      expect(report.technology, 'Li-ion');
      expect(report.chargeCounterUah, 3300000);
      expect(report.capacityPercent, 76.0);
      expect(report.voltageV, 3.82);
      expect(report.temperatureC, 31.5);
      expect(report.healthPercent, closeTo(110.0, 0.001));
    });

    test('无电池 / 缺失时 present=false 且字段为 null', () {
      final absent =
          PerfBatteryHealthReport.fromJson(<String, dynamic>{'present': false});
      expect(absent.present, isFalse);
      expect(absent.chargeFullUah, isNull);
      expect(absent.cycleCount, isNull);
      expect(absent.healthPercent, isNull);

      final empty =
          PerfBatteryHealthReport.fromJson(const <String, dynamic>{});
      expect(empty.present, isFalse);
      expect(empty.present, isFalse);
    });

    test('healthPercent 在缺一侧 / 设计为 0 时为 null', () {
      final oneSided = PerfBatteryHealthReport.fromJson(<String, dynamic>{
        'present': true,
        'charge_full_uah': 4400000,
      });
      expect(oneSided.healthPercent, isNull);

      final zeroDesign = PerfBatteryHealthReport.fromJson(<String, dynamic>{
        'present': true,
        'charge_full_uah': 4400000,
        'charge_full_design_uah': 0,
      });
      expect(zeroDesign.healthPercent, isNull);
    });
  });

  group('PerfStorageReport (perf.storage)', () {
    test('解码卷列表', () {
      final report = PerfStorageReport.fromJson(<String, dynamic>{
        'volumes': <dynamic>[
          <String, dynamic>{
            'mount': '/data',
            'fs': 'f2fs',
            'total_kb': 102400000,
            'free_kb': 40960000,
            'used_kb': 61440000,
            'used_percent': 60.0,
          },
          <String, dynamic>{
            'mount': '/storage/emulated',
            'fs': 'sdcardfs',
            'total_kb': 102400000,
            'free_kb': 40960000,
            'used_kb': 61440000,
            'used_percent': 60.0,
          },
        ],
      });

      expect(report.volumes.length, 2);
      expect(report.volumes[0].mount, '/data');
      expect(report.volumes[0].fs, 'f2fs');
      expect(report.volumes[0].totalKb, 102400000);
      expect(report.volumes[0].usedPercent, 60.0);
      expect(report.volumes[1].mount, '/storage/emulated');
    });

    test('缺失字段宽容为空列表', () {
      final report = PerfStorageReport.fromJson(const <String, dynamic>{});
      expect(report.volumes, isEmpty);
    });
  });

  group('CpuReport 扩展 (available_governors / freq_residency)', () {
    test('解码调速器与频率驻留', () {
      final report = CpuReport.fromJson(<String, dynamic>{
        'governor': 'schedutil',
        'available_governors': <dynamic>['schedutil', 'performance', 'powersave'],
        'freq_residency': <dynamic>[
          <String, dynamic>{'freq_mhz': 300, 'ticks': 100},
          <String, dynamic>{'freq_mhz': 1800.0, 'ticks': '900'},
        ],
      });

      expect(report.availableGovernors,
          <String>['schedutil', 'performance', 'powersave']);
      expect(report.freqResidency.length, 2);
      expect(report.freqResidency[0].freqMhz, 300.0);
      expect(report.freqResidency[0].ticks, 100);
      expect(report.freqResidency[1].freqMhz, 1800.0);
      expect(report.freqResidency[1].ticks, 900);
    });

    test('缺失时为空列表', () {
      final report = CpuReport.fromJson(const <String, dynamic>{});
      expect(report.availableGovernors, isEmpty);
      expect(report.freqResidency, isEmpty);
    });
  });

  group('NetworkInterface 扩展 (错误 / 丢包计数)', () {
    test('解码错误计数并计算 hasErrors / errorTotal', () {
      final iface = NetworkInterface.fromJson(<String, dynamic>{
        'name': 'rmnet0',
        'rx_errors': 2,
        'tx_errors': 1,
        'rx_dropped': 3,
        'tx_dropped': 4,
        'rx_fifo': 5,
        'tx_fifo': 6,
        'rx_frame': 7,
        'rx_compressed': 8,
        'tx_compressed': 9,
        'multicast': 10,
      });

      expect(iface.rxErrors, 2);
      expect(iface.txErrors, 1);
      expect(iface.rxDropped, 3);
      expect(iface.txDropped, 4);
      expect(iface.rxFifo, 5);
      expect(iface.txFifo, 6);
      expect(iface.rxFrame, 7);
      expect(iface.rxCompressed, 8);
      expect(iface.txCompressed, 9);
      expect(iface.multicast, 10);
      expect(iface.hasErrors, isTrue);
      // 2+1+3+4+5+6+7+8+9 = 45（multicast 不计入错误）。
      expect(iface.errorTotal, 45);
    });

    test('全为零时 hasErrors=false', () {
      final iface = NetworkInterface.fromJson(<String, dynamic>{'name': 'lo'});
      expect(iface.hasErrors, isFalse);
      expect(iface.errorTotal, 0);
    });
  });

  group('PerfModule facade (深度报告)', () {
    test('pressure/cooling/batteryHealth/storage 走对应方法名并解码', () async {
      final gateway = _FakeGateway(<String, Uint8List>{
        PerfMethods.pressure: _okEnvelope(<String, dynamic>{
          'cpu': <String, dynamic>{
            'some': <String, dynamic>{'avg10': 1.0},
          },
        }),
        PerfMethods.cooling: _okEnvelope(<String, dynamic>{
          'count': 1,
          'devices': <dynamic>[
            <String, dynamic>{
              'device': 'cooling_device0',
              'type': 'cpu',
              'cur_state': 1,
              'max_state': 5,
            },
          ],
        }),
        PerfMethods.batteryHealth: _okEnvelope(<String, dynamic>{
          'present': true,
          'charge_full_uah': 4000000,
          'charge_full_design_uah': 4000000,
        }),
        PerfMethods.storage: _okEnvelope(<String, dynamic>{
          'volumes': <dynamic>[
            <String, dynamic>{'mount': '/data', 'used_percent': 50.0},
          ],
        }),
      });
      final facade = PerfModule(gateway: gateway);

      final pressure = await facade.pressure();
      final cooling = await facade.cooling();
      final battery = await facade.batteryHealth();
      final storage = await facade.storage();

      expect(pressure.cpuSome?.avg10, 1.0);
      expect(cooling.devices.single.type, 'cpu');
      expect(battery.healthPercent, closeTo(100.0, 0.001));
      expect(storage.volumes.single.mount, '/data');
      expect(gateway.methods, <String>[
        PerfMethods.pressure,
        PerfMethods.cooling,
        PerfMethods.batteryHealth,
        PerfMethods.storage,
      ]);
    });
  });
}
