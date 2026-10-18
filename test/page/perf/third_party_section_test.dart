import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shizuku_api/shizuku_api.dart';

import 'package:gstore/compent/line_chart.dart';
import 'package:gstore/core/perf/perf_interval_store.dart';
import 'package:gstore/core/perf/perf_target_store.dart';
import 'package:gstore/core/perf/third_party_perf_service.dart';
import 'package:gstore/core/rust/perf/PerfContract.dart';
import 'package:gstore/page/perf/third_party_section.dart';

/// 假 Shizuku：可编程 binder / 授权状态，不触达平台通道。
class _FakeShizuku extends ShizukuApi {
  _FakeShizuku({this.binder = false, this.granted = false});

  final bool binder;
  final bool granted;

  @override
  Future<bool?> pingBinder() async => binder;

  @override
  Future<bool?> checkPermission() async => granted;

  @override
  Future<bool?> requestPermission() async => granted;

  @override
  Future<String?> runCommand(String command) async => null;
}

/// 假服务：绕过 `installed_apps` 平台通道（测试环境无宿主，调用会挂起）。
class _FakeService extends ThirdPartyPerfService {
  _FakeService({bool binder = false, bool granted = false})
      : super(
          runner: (cmd) async => null,
          shizukuApi: _FakeShizuku(binder: binder, granted: granted),
        );

  @override
  Future<List<AppTarget>> listInstalledApps() async => const <AppTarget>[];
}

/// 已授权 + 可采样的假服务：绕过平台通道，返回固定应用与丰富样本。
class _ReadyService extends ThirdPartyPerfService {
  _ReadyService()
      : super(
          runner: (cmd) async => null,
          shizukuApi: _FakeShizuku(binder: true, granted: true),
        );

  @override
  Future<List<AppTarget>> listInstalledApps() async => const <AppTarget>[
        AppTarget(package: 'com.example.app', label: '示例应用'),
      ];

  @override
  Future<ThirdPartySample> sampleDetailed(
    String package, {
    int? prevFrameCount,
    int? prevTsMs,
    int? prevRxBytes,
    int? prevTxBytes,
  }) async =>
      const ThirdPartySample(
        tsMs: 2000,
        metrics: ThirdPartyAppMetrics(
          package: 'com.example.app',
          pid: 4242,
          uid: 10123,
          running: true,
          threads: 42,
          cpuPercent: 12.5,
          memPssKb: 204800,
          memSummary: PerfMemSummary(
            javaHeapKb: 81920,
            nativeHeapKb: 20480,
            codeKb: 40960,
            stackKb: 1024,
            graphicsKb: 30720,
            privateOtherKb: 10240,
            systemKb: 5120,
            totalPssKb: 204800,
          ),
          processes: <PerfProcessInfo>[
            PerfProcessInfo(
              pid: 4242,
              ppid: 1000,
              name: 'com.example.app',
              rssKb: 204800,
            ),
          ],
          net: PerfNetCounters(uid: 10123, rxBytes: 1048576, txBytes: 524288),
          render: PerfRenderBreakdown(
            frameCount: 120,
            fps: 58.5,
            jankCount: 4,
            avgTotalMs: 11.2,
            p50TotalMs: 8.0,
            p90TotalMs: 16.5,
            p99TotalMs: 24.0,
            avgUiMs: 5.1,
            avgDrawMs: 3.2,
            avgGpuMs: 2.9,
          ),
          power: PerfPowerAttribution(
            mah: 3.42,
            wakeLockMs: 65000,
            mobileRadioMah: 0.8,
            wifiMah: 1.2,
            screenMah: 1.0,
            cpuMah: 0.42,
          ),
          appInfo: PerfAppInfo(
            versionName: '9.1',
            versionCode: 91,
            targetSdk: 33,
            minSdk: 24,
            firstInstall: '2023-05-01 12:34:56',
            lastUpdate: '2024-06-02 08:00:00',
            codePath: '/data/app/com.example.app/base.apk',
            dataDir: '/data/user/0/com.example.app',
            isSystem: false,
            enabled: true,
            requestedPermissions: <String>['pm.camera', 'pm.internet'],
            grantedPermissions: <String>['pm.internet'],
            activityCount: 5,
            serviceCount: 3,
            receiverCount: 2,
            providerCount: 1,
          ),
          smaps: PerfSmaps(
            pssKb: 307200,
            rssKb: 409600,
            sharedCleanKb: 10240,
            sharedDirtyKb: 2048,
            privateCleanKb: 8192,
            privateDirtyKb: 131072,
          ),
          crashes: PerfCrashReport(
            crashCount: 2,
            anrCount: 1,
            lastCrash: '2024-06-01 10:00:00',
            lastAnr: '2024-06-02 11:00:00',
            recent: <PerfCrashEntry>[
              PerfCrashEntry(
                kind: 'crash',
                time: '2024-06-01 10:00:00',
                summary: 'java.lang.NullPointerException',
              ),
              PerfCrashEntry(
                kind: 'anr',
                time: '2024-06-02 11:00:00',
                summary: 'Input dispatching timed out',
              ),
            ],
          ),
          foreground: PerfForeground(isForeground: true),
          wakeLocks: <PerfWakeLock>[
            PerfWakeLock(name: 'AudioMix', ms: 90000),
            PerfWakeLock(name: 'partial_wakelock', ms: 12000),
          ],
          rxBytesPerSec: 1536,
          txBytesPerSec: 512,
        ),
      );
}

/// 已授权 + 可采样、但 `render` / `power` 均为 `null` 的假服务（验收「不可用」）。
class _NoExtrasService extends ThirdPartyPerfService {
  _NoExtrasService()
      : super(
          runner: (cmd) async => null,
          shizukuApi: _FakeShizuku(binder: true, granted: true),
        );

  @override
  Future<List<AppTarget>> listInstalledApps() async => const <AppTarget>[
        AppTarget(package: 'com.example.app', label: '示例应用'),
      ];

  @override
  Future<ThirdPartySample> sampleDetailed(
    String package, {
    int? prevFrameCount,
    int? prevTsMs,
    int? prevRxBytes,
    int? prevTxBytes,
  }) async =>
      const ThirdPartySample(
        tsMs: 2000,
        metrics: ThirdPartyAppMetrics(
          package: 'com.example.app',
          pid: 4242,
          running: true,
          cpuPercent: 12.5,
          memPssKb: 204800,
        ),
      );
}

/// 经可搜索弹层选择「示例应用」。
Future<void> _selectApp(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('perf_third_party_pick')));
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  await tester.tap(find.text('示例应用'));
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Widget _harness(
  ThirdPartyPerfService service, {
  PerfIntervalStore? store,
  PerfTargetStore? targetStore,
}) =>
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: ThirdPartyAppSection(
            service: service,
            intervalStore: store,
            targetStore: targetStore,
          ),
        ),
      ),
    );

/// 推进若干帧完成异步检测（不用 pumpAndSettle：AppLoading 无限动画会超时）。
Future<void> _settleAsync(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Shizuku 不可用：渲染「需要 Shizuku」状态 + 授权入口（不崩溃）',
      (tester) async {
    await tester.pumpWidget(_harness(_FakeService()));
    await _settleAsync(tester);

    expect(find.text('第三方应用'), findsOneWidget);
    expect(find.text('需要 Shizuku'), findsOneWidget);
    expect(find.byKey(const Key('perf_third_party_authorize')), findsOneWidget);
    expect(find.byKey(const Key('perf_third_party_pick')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Shizuku 已授权：显示可用状态，无「授权 / 检查」按钮', (tester) async {
    await tester.pumpWidget(_harness(_FakeService(binder: true, granted: true)));
    await _settleAsync(tester);

    expect(find.text('第三方应用'), findsOneWidget);
    expect(find.text('Shizuku 已授权'), findsOneWidget);
    expect(find.text('需要 Shizuku'), findsNothing);
    expect(find.byKey(const Key('perf_third_party_authorize')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('点击「选择应用」打开可搜索的应用弹层', (tester) async {
    await tester.pumpWidget(_harness(_FakeService(binder: true, granted: true)));
    await _settleAsync(tester);

    await tester.tap(find.byKey(const Key('perf_third_party_pick')));
    // 弹层入场动画。
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    // 弹层标题 + 空列表占位（installed_apps 通道缺失 → 空列表）。
    expect(find.text('选择应用'), findsWidgets);
    expect(find.text('未找到已安装应用'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('已授权 + 采样后：渲染内存细分 / 进程线程 / 网络卡片与间隔选择器',
      (tester) async {
    await tester.pumpWidget(_harness(_ReadyService()));
    await _settleAsync(tester);

    // 选择应用（经可搜索弹层）。
    await tester.tap(find.byKey(const Key('perf_third_party_pick')));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.tap(find.text('示例应用'));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    // 采样一次。
    await tester.tap(find.byKey(const Key('perf_third_party_sample')));
    await _settleAsync(tester);

    expect(find.text('内存细分'), findsOneWidget);
    expect(find.text('进程 / 线程'), findsOneWidget);
    expect(find.text('网络'), findsOneWidget);
    expect(find.text('渲染细分'), findsOneWidget);
    expect(find.text('耗电 / 唤醒'), findsOneWidget);
    expect(find.byKey(const Key('perf_third_party_interval')), findsOneWidget);
    // 线程数 42。
    expect(find.text('42'), findsOneWidget);
    // 内存细分 + 网络速率折线。
    expect(find.text('Java 堆'), findsOneWidget);
    expect(find.text('Total PSS'), findsOneWidget);
    expect(find.byType(LineChart), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('采样后：渲染细分卡片显示 FPS / jank / 百分位 / UI-Draw-GPU 均值',
      (tester) async {
    await tester.pumpWidget(_harness(_ReadyService()));
    await _settleAsync(tester);
    await _selectApp(tester);
    await tester.tap(find.byKey(const Key('perf_third_party_sample')));
    await _settleAsync(tester);

    expect(find.text('渲染细分'), findsOneWidget);
    expect(find.text('58.5'), findsOneWidget); // FPS
    expect(find.text('11.20 ms'), findsOneWidget); // 平均
    expect(find.text('16.50 ms'), findsOneWidget); // P90
    expect(find.text('24.00 ms'), findsOneWidget); // P99
    expect(find.text('5.10 ms'), findsOneWidget); // UI
    expect(find.text('3.20 ms'), findsOneWidget); // Draw
    expect(find.text('2.90 ms'), findsOneWidget); // GPU
    expect(tester.takeException(), isNull);
  });

  testWidgets('采样后：耗电 / 唤醒卡片显示 mAh / 唤醒时长 / 组件 mAh',
      (tester) async {
    await tester.pumpWidget(_harness(_ReadyService()));
    await _settleAsync(tester);
    await _selectApp(tester);
    await tester.tap(find.byKey(const Key('perf_third_party_sample')));
    await _settleAsync(tester);

    expect(find.text('耗电 / 唤醒'), findsOneWidget);
    expect(find.text('3.42 mAh'), findsOneWidget); // 估算耗电
    expect(find.text('1 min 5 s'), findsOneWidget); // 唤醒 65000ms
    expect(find.text('0.80 mAh'), findsOneWidget); // 移动网络
    expect(find.text('0.42 mAh'), findsOneWidget); // CPU
    expect(tester.takeException(), isNull);
  });

  testWidgets('无 render / power：渲染细分与耗电卡片显示「不可用」', (tester) async {
    await tester.pumpWidget(_harness(_NoExtrasService()));
    await _settleAsync(tester);
    await _selectApp(tester);
    await tester.tap(find.byKey(const Key('perf_third_party_sample')));
    await _settleAsync(tester);

    expect(find.text('渲染细分'), findsOneWidget);
    expect(find.text('渲染细分不可用'), findsOneWidget);
    expect(find.text('耗电 / 唤醒'), findsOneWidget);
    expect(find.text('耗电数据不可用'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('采样后：渲染应用信息 / smaps / 前台 / 崩溃 / 唤醒锁卡片',
      (tester) async {
    await tester.pumpWidget(_harness(_ReadyService()));
    await _settleAsync(tester);
    await _selectApp(tester);
    await tester.tap(find.byKey(const Key('perf_third_party_sample')));
    await _settleAsync(tester);

    // 应用信息。
    expect(find.text('应用信息'), findsOneWidget);
    expect(find.text('9.1 (91)'), findsOneWidget);
    expect(find.text('target 33 / min 24'), findsOneWidget);
    expect(find.text('非系统应用'), findsOneWidget);
    expect(find.text('已启用'), findsOneWidget);
    expect(find.textContaining('base.apk'), findsOneWidget);

    // 精确内存（smaps，MB）。
    expect(find.text('精确内存 (smaps)'), findsOneWidget);
    expect(find.text('300.0 MB'), findsOneWidget); // PSS
    expect(find.text('400.0 MB'), findsOneWidget); // RSS

    // 前台状态。
    expect(find.text('前台状态'), findsOneWidget);
    expect(find.text('前台'), findsOneWidget);

    // 崩溃 / ANR。
    expect(find.text('崩溃 / ANR'), findsOneWidget);
    expect(find.text('java.lang.NullPointerException'), findsOneWidget);
    expect(find.text('Input dispatching timed out'), findsOneWidget);

    // 唤醒锁明细（humanized 时长）。
    expect(find.text('唤醒锁明细'), findsOneWidget);
    expect(find.text('AudioMix'), findsOneWidget);
    expect(find.text('1 min 30 s'), findsOneWidget);
    expect(find.text('12.0 s'), findsOneWidget);

    expect(tester.takeException(), isNull);
  });

  testWidgets('无应用深入数据：新卡片显示「不可用」/「无记录」', (tester) async {
    await tester.pumpWidget(_harness(_NoExtrasService()));
    await _settleAsync(tester);
    await _selectApp(tester);
    await tester.tap(find.byKey(const Key('perf_third_party_sample')));
    await _settleAsync(tester);

    expect(find.text('应用信息'), findsOneWidget);
    expect(find.text('应用信息不可用'), findsOneWidget);
    expect(find.text('精确内存 (smaps)'), findsOneWidget);
    expect(find.text('smaps 不可用'), findsOneWidget);
    expect(find.text('前台状态'), findsOneWidget);
    expect(find.text('前台状态不可用'), findsOneWidget);
    expect(find.text('崩溃 / ANR'), findsOneWidget);
    expect(find.text('崩溃记录不可用'), findsOneWidget);
    expect(find.text('唤醒锁明细'), findsOneWidget);
    expect(find.text('无唤醒锁记录'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('还原持久化间隔：预置 5s → 开启实时后显示「每 5 秒」', (tester) async {
    final store = InMemoryPerfIntervalStore(5);
    await tester.pumpWidget(_harness(_ReadyService(), store: store));
    await _settleAsync(tester);
    await _selectApp(tester);

    await tester.tap(find.byKey(const Key('perf_third_party_live_switch')));
    await _settleAsync(tester);
    expect(find.text('实时采集中（每 5 秒）'), findsOneWidget);

    // 卸载以取消实时定时器（避免 pending timer）。
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('切换间隔即持久化：默认 2s → 点 5s → 存储记录 5', (tester) async {
    final store = InMemoryPerfIntervalStore();
    await tester.pumpWidget(_harness(_ReadyService(), store: store));
    await _settleAsync(tester);
    await _selectApp(tester);

    await tester.tap(find.byKey(const Key('perf_third_party_live_switch')));
    await _settleAsync(tester);
    expect(find.text('实时采集中（每 2 秒）'), findsOneWidget);

    await tester.tap(find.byKey(const Key('perf_third_party_interval_5')));
    await _settleAsync(tester);
    expect(find.text('实时采集中（每 5 秒）'), findsOneWidget);
    expect(await store.load(), 5);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('选择目标即持久化最近目标（包名 + 展示名）', (tester) async {
    final store = InMemoryPerfTargetStore();
    await tester.pumpWidget(_harness(_ReadyService(), targetStore: store));
    await _settleAsync(tester);
    expect(await store.load(), isNull);

    await _selectApp(tester);
    await _settleAsync(tester);

    final saved = await store.load();
    expect(saved, isNotNull);
    expect(saved!.package, 'com.example.app');
    expect(saved.label, '示例应用');
    expect(tester.takeException(), isNull);
  });

  testWidgets('预置最近目标 → 打开即预选（仍在已安装列表中）', (tester) async {
    final store = InMemoryPerfTargetStore(
      const PerfPinnedTarget(package: 'com.example.app', label: '示例应用'),
    );
    await tester.pumpWidget(_harness(_ReadyService(), targetStore: store));
    await _settleAsync(tester);

    // 预选后：选择器显示已选应用（非「未选择应用」），并出现「采样一次」入口。
    expect(find.text('未选择应用'), findsNothing);
    expect(find.text('示例应用'), findsOneWidget);
    expect(find.byKey(const Key('perf_third_party_sample')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('预置目标但应用已卸载 → 不预选（保持未选择）', (tester) async {
    final store = InMemoryPerfTargetStore(
      const PerfPinnedTarget(package: 'com.gone.app', label: '已卸载应用'),
    );
    await tester.pumpWidget(_harness(_ReadyService(), targetStore: store));
    await _settleAsync(tester);

    expect(find.text('未选择应用'), findsOneWidget);
    expect(find.text('已卸载应用'), findsNothing);
    expect(find.byKey(const Key('perf_third_party_sample')), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
