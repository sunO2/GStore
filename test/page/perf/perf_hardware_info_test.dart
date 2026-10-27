// 硬件规格卡片（设备信息 / CPU·GPU / 屏幕特性 / 传感器）渲染测试。
// 数据经 Provider 覆盖注入，不触达 device_info_plus / 原生模块 / FFI。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/core/rust/perf/PerfContract.dart';
import 'package:gstore/core/rust/perf/PerfModule.dart';
import 'package:gstore/page/perf/logic.dart';
import 'package:gstore/page/perf/perf_hardware_info.dart';
import 'package:gstore/page/perf/state.dart';

class _FakeNotifier extends PerfMonitorNotifier {
  _FakeNotifier(this._initial);

  final PerfPageState _initial;

  @override
  PerfPageState build() => _initial;
}

PerfHardwareData _data() => const PerfHardwareData(
      device: DeviceReport(
        kernelVersion: 'Linux version 5.10.1',
        hardware: 'qcom',
        cpuName: 'Snapdragon 888',
        model: 'Pixel 5',
        androidRelease: '14',
        boardPlatform: 'lahaina',
        coreCount: 8,
      ),
      tunables: TunablesReport(
        cpuClusters: <PerfCpuCluster>[
          PerfCpuCluster(
            policy: 'policy0',
            relatedCpus: <int>[0, 1, 2, 3],
            governor: 'schedutil',
            minFreqMhz: 300,
            maxFreqMhz: 1800,
            availableFrequenciesMhz: <double>[300, 1000, 1800],
            availableGovernors: <String>['schedutil', 'performance'],
          ),
        ],
        gpu: PerfGpuTunables(
          availableFrequenciesMhz: <double>[300, 800],
          governor: 'msm-adreno-tz',
          powerLevels: 5,
        ),
      ),
      sensors: SensorsReport(
        count: 1,
        sensors: <SensorInfo>[
          SensorInfo(
            name: 'LSM6DSO Accelerometer',
            vendor: 'STMicroelectronics',
            typeId: 1,
            typeName: '加速度计',
            stringType: 'android.sensor.accelerometer',
            resolution: 0.001,
            minDelayUs: 5000,
            fifoMaxEventCount: 3000,
            fifoReservedEventCount: 128,
            reportingMode: 0,
            reportingModeName: '连续',
            wakeUp: true,
          ),
        ],
      ),
    );

PerfPageState _state() => const PerfPageState(
      loading: false,
      availability: PerfAvailability.ready,
      cpu: CpuReport(
        usagePercent: 30,
        perCoreUsage: <double>[10, 20, 30, 40],
        coreCount: 4,
        cores: <PerfCpuCore>[
          PerfCpuCore(id: 0, freqMhz: 1800),
          PerfCpuCore(id: 1, freqMhz: 1800),
          PerfCpuCore(id: 2, freqMhz: 1000),
          PerfCpuCore(id: 3, freqMhz: 300),
        ],
      ),
      gpu: GpuReport(name: 'Adreno 660', freqMhz: 800, busyPercent: 12),
    );

void main() {
  testWidgets('设备 / CPU·GPU / 屏幕特性 / 传感器卡片渲染', (tester) async {
    tester.view.physicalSize = const Size(1080, 6000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          perfHardwareDataProvider.overrideWith((ref) async => _data()),
          perfMonitorProvider.overrideWith(() => _FakeNotifier(_state())),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: Column(
                children: <Widget>[
                  PerfDeviceSpecCard(),
                  PerfCpuGpuSpecCard(),
                  PerfDisplayFeaturesCard(),
                  PerfSensorsCard(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 设备信息
    expect(find.text('设备信息'), findsOneWidget);
    expect(find.text('Pixel 5'), findsNWidgets(2));
    expect(find.text('Snapdragon 888'), findsOneWidget);
    expect(find.text('Linux version 5.10.1'), findsOneWidget);

    // CPU 簇 / GPU
    expect(find.text('处理器 / 图形'), findsOneWidget);
    expect(find.text('policy0 · CPU 0-3'), findsOneWidget);
    expect(find.text('schedutil'), findsOneWidget);
    expect(find.text('300 ~ 1800 MHz'), findsNWidgets(2));
    expect(find.text('Adreno 660'), findsOneWidget);
    expect(find.text('800 MHz'), findsOneWidget);

    // 屏幕 / 特性
    expect(find.text('屏幕 / 存储 / 特性'), findsOneWidget);
    expect(find.text('分辨率'), findsOneWidget);
    expect(find.text('系统特性'), findsOneWidget);

    // 传感器
    expect(find.text('传感器'), findsOneWidget);
    expect(find.text('加速度计'), findsOneWidget);
    expect(find.text('LSM6DSO Accelerometer'), findsOneWidget);
    expect(find.textContaining('STMicroelectronics'), findsOneWidget);
    expect(find.text('连续'), findsOneWidget);
    expect(find.text('唤醒'), findsOneWidget);
    expect(find.text('5.0 ms'), findsOneWidget);

    expect(tester.takeException(), isNull);
  });
}
