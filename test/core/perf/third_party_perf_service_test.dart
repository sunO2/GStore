import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shizuku_api/shizuku_api.dart';

import 'package:gstore/core/perf/third_party_perf_service.dart';
import 'package:gstore/core/rust/perf/PerfContract.dart';
import 'package:gstore/core/rust/perf/PerfModule.dart';

/// 假网关：按调用次数返回递增的 `frame_count` / `net` 计数器，其余字段固定；
/// **不触碰 FFI**。
class _FakePerfGateway implements PerfModuleGateway {
  _FakePerfGateway({
    this.unavailable = false,
    this.frameCounts = const [100, 130],
    this.netRxs = const [1000, 3000],
    this.netTxs = const [500, 1500],
  });

  final bool unavailable;
  final List<int> frameCounts;
  final List<int> netRxs;
  final List<int> netTxs;
  int calls = 0;
  Uint8List? lastPayload;
  final StreamController<PerfRawEvent> _events =
      StreamController<PerfRawEvent>.broadcast();

  @override
  Future<Uint8List> call(String method, [Uint8List? payload]) async {
    if (unavailable) throw PerfModuleUnavailableException();
    expect(method, PerfMethods.parseAppDumps);
    lastPayload = payload;
    final index = calls;
    calls++;
    final frames = frameCounts[index.clamp(0, frameCounts.length - 1)];
    final rx = netRxs[index.clamp(0, netRxs.length - 1)];
    final tx = netTxs[index.clamp(0, netTxs.length - 1)];
    return Uint8List.fromList(
      utf8.encode(
        jsonEncode(<String, dynamic>{
          'ok': true,
          'data': <String, dynamic>{
            'package': 'com.example.app',
            'pid': 4242,
            'uid': 10123,
            'running': true,
            'threads': 42,
            'cpu_percent': 25.5,
            'mem_pss_kb': 204800,
            'mem_rss_kb': 300000,
            'mem_java_heap_kb': 40960,
            'mem_native_heap_kb': 20480,
            'mem_private_dirty_kb': 65536,
            'mem_summary': <String, dynamic>{
              'java_heap_kb': 81920,
              'native_heap_kb': 20480,
              'code_kb': 40960,
              'stack_kb': 1024,
              'graphics_kb': 30720,
              'private_other_kb': 10240,
              'system_kb': 5120,
              'total_pss_kb': 204800,
            },
            'processes': <Map<String, dynamic>>[
              <String, dynamic>{
                'pid': 4242,
                'ppid': 1000,
                'rss_kb': 204800,
                'name': 'com.example.app',
              },
            ],
            'net': <String, dynamic>{
              'uid': 10123,
              'rx_bytes': rx,
              'tx_bytes': tx,
            },
            'render': <String, dynamic>{
              'frame_count': frames,
              'fps': 58.5,
              'jank_count': 3,
              'avg_total_ms': 11.2,
              'p50_total_ms': 8.0,
              'p90_total_ms': 16.5,
              'p99_total_ms': 24.0,
              'avg_ui_ms': 5.1,
              'avg_draw_ms': 3.2,
              'avg_gpu_ms': 2.9,
            },
            'power': <String, dynamic>{
              'mah': 3.42,
              'wake_lock_ms': 65000,
              'mobile_radio_mah': 0.8,
              'wifi_mah': 1.2,
              'screen_mah': 1.0,
              'cpu_mah': 0.42,
            },
            'app_info': <String, dynamic>{
              'version_name': '9.1',
              'version_code': 91,
              'target_sdk': 33,
              'min_sdk': 24,
              'first_install': '2023-05-01 12:34:56',
              'last_update': '2024-06-01 08:00:00',
              'code_path': '/data/app/com.example.app/base.apk',
              'data_dir': '/data/user/0/com.example.app',
              'is_system': false,
              'enabled': true,
              'requested_permissions': <String>[
                'android.permission.CAMERA',
                'android.permission.INTERNET',
              ],
              'granted_permissions': <String>['android.permission.INTERNET'],
              'activity_count': 5,
              'service_count': 3,
              'receiver_count': 2,
              'provider_count': 1,
            },
            'smaps': <String, dynamic>{
              'pss_kb': 204800,
              'rss_kb': 300000,
              'shared_clean_kb': 4096,
              'shared_dirty_kb': 2048,
              'private_clean_kb': 8192,
              'private_dirty_kb': 65536,
            },
            'crashes': <String, dynamic>{
              'crash_count': 2,
              'anr_count': 1,
              'last_crash': '2024-06-01 10:00:00',
              'last_anr': '2024-06-02 11:00:00',
              'recent': <Map<String, dynamic>>[
                <String, dynamic>{
                  'kind': 'crash',
                  'time': '2024-06-01 10:00:00',
                  'summary': 'java.lang.NullPointerException',
                },
                <String, dynamic>{
                  'kind': 'anr',
                  'time': '2024-06-02 11:00:00',
                  'summary': 'Input dispatching timed out',
                },
              ],
            },
            'foreground': <String, dynamic>{'is_foreground': true},
            'wake_locks': <Map<String, dynamic>>[
              <String, dynamic>{'name': 'AudioMix', 'ms': 90000},
              <String, dynamic>{'name': 'partial_wakelock', 'ms': 12000},
            ],
            'frame_count': frames,
            'janky_frames': 3,
            'janky_percent': 1.5,
            'p50_ms': 8.0,
            'p90_ms': 12.0,
            'p95_ms': 15.0,
            'p99_ms': 24.0,
            'missed_vsync': 3,
            'high_input_latency': 0,
            'slow_ui_thread': 1,
            'slow_bitmap_uploads': 0,
            'slow_draw': 2,
          },
        }),
      ),
    );
  }

  @override
  Stream<PerfRawEvent> get events => _events.stream;
}

/// 假 Shizuku：可编程 binder / 授权状态，不触达平台通道。
class _FakeShizuku extends ShizukuApi {
  _FakeShizuku({
    this.binder = true,
    this.granted = true,
    this.grantOnRequest = true,
  });

  bool binder;
  bool granted;
  bool grantOnRequest;

  @override
  Future<bool?> pingBinder() async => binder;

  @override
  Future<bool?> checkPermission() async => granted;

  @override
  Future<bool?> requestPermission() async {
    granted = grantOnRequest;
    return grantOnRequest;
  }

  @override
  Future<String?> runCommand(String command) async => null;
}

/// 罐头命令输出：按命令前缀返回对应 dumpsys 文本。
_CommandRecorder _runner() {
  final recorder = _CommandRecorder();
  return recorder;
}

class _CommandRecorder {
  final List<String> commands = <String>[];

  Future<String?> run(String command) async {
    commands.add(command);
    if (command.startsWith('pidof')) return '4242\n';
    if (command.startsWith('dumpsys cpuinfo')) return 'cpuinfo text';
    if (command.startsWith('dumpsys meminfo')) return 'meminfo text';
    if (command.startsWith('dumpsys gfxinfo') && command.endsWith('framestats')) {
      return 'framestats text';
    }
    if (command.startsWith('dumpsys gfxinfo')) return 'gfxinfo text';
    if (command.startsWith('cmd package list packages')) {
      return 'package:com.example.app uid:10123\n'
          'package:com.other.app uid:10124\n';
    }
    if (command.startsWith('ps -A')) return 'ps text';
    if (command.startsWith('cat /proc/') && command.endsWith('smaps_rollup')) {
      return 'smaps text';
    }
    if (command.startsWith('cat /proc/')) return 'Threads:\t42\n';
    if (command.startsWith('dumpsys netstats')) return 'netstats text';
    if (command.startsWith('dumpsys batterystats')) return 'batterystats text';
    if (command.startsWith('dumpsys package')) return 'package text';
    if (command.startsWith('dumpsys dropbox') &&
        command.contains('data_app_crash')) {
      return 'crashlog text';
    }
    if (command.startsWith('dumpsys dropbox')) return 'anrlog text';
    if (command.startsWith('dumpsys activity')) return 'activity text';
    return null;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ThirdPartyAppMetrics 解码', () {
    test('解码完整 schema', () {
      final metrics = ThirdPartyAppMetrics.fromJson(<String, dynamic>{
        'package': 'com.example.app',
        'pid': 4242,
        'running': true,
        'cpu_percent': 25.5,
        'mem_pss_kb': 204800,
        'mem_rss_kb': 300000,
        'mem_java_heap_kb': 40960,
        'mem_native_heap_kb': 20480,
        'mem_private_dirty_kb': 65536,
        'frame_count': 1234,
        'janky_frames': 7,
        'janky_percent': 2.5,
        'p50_ms': 8.0,
        'p90_ms': 12.0,
        'p95_ms': 15.0,
        'p99_ms': 24.0,
        'missed_vsync': 3,
        'high_input_latency': 1,
        'slow_ui_thread': 2,
        'slow_bitmap_uploads': 0,
        'slow_draw': 4,
      });

      expect(metrics.package, 'com.example.app');
      expect(metrics.pid, 4242);
      expect(metrics.running, isTrue);
      expect(metrics.cpuPercent, 25.5);
      expect(metrics.memPssKb, 204800);
      expect(metrics.memRssKb, 300000);
      expect(metrics.memJavaHeapKb, 40960);
      expect(metrics.memNativeHeapKb, 20480);
      expect(metrics.memPrivateDirtyKb, 65536);
      expect(metrics.frameCount, 1234);
      expect(metrics.jankyFrames, 7);
      expect(metrics.jankyPercent, 2.5);
      expect(metrics.p50Ms, 8.0);
      expect(metrics.p99Ms, 24.0);
      expect(metrics.missedVsync, 3);
      expect(metrics.slowDraw, 4);
      // fps 不由 Rust 返回。
      expect(metrics.fps, isNull);
    });

    test('缺字段 / null / 数字字符串均宽容', () {
      final empty = ThirdPartyAppMetrics.fromJson(const <String, dynamic>{});
      expect(empty.package, '');
      expect(empty.pid, isNull);
      expect(empty.running, isFalse);
      expect(empty.cpuPercent, isNull);
      expect(empty.memPssKb, isNull);
      expect(empty.frameCount, isNull);

      final coerced = ThirdPartyAppMetrics.fromJson(<String, dynamic>{
        'pid': '99',
        'cpu_percent': '12.5',
        'mem_pss_kb': '1024',
        'running': false,
      });
      expect(coerced.pid, 99);
      expect(coerced.cpuPercent, 12.5);
      expect(coerced.memPssKb, 1024);
      expect(coerced.running, isFalse);
    });
  });

  group('扩展模型解码', () {
    test('PerfMemSummary 宽容解码（含数字字符串 / 缺字段）', () {
      final mem = PerfMemSummary.fromJson(<String, dynamic>{
        'java_heap_kb': 81920,
        'code_kb': '40960',
        'total_pss_kb': 204800,
      });
      expect(mem.javaHeapKb, 81920);
      expect(mem.codeKb, 40960);
      expect(mem.totalPssKb, 204800);
      expect(mem.nativeHeapKb, isNull);
      expect(mem.stackKb, isNull);

      final empty = PerfMemSummary.fromJson(const <String, dynamic>{});
      expect(empty.javaHeapKb, isNull);
      expect(empty.totalPssKb, isNull);
    });

    test('PerfNetCounters 宽容解码', () {
      final net = PerfNetCounters.fromJson(<String, dynamic>{
        'uid': 10123,
        'rx_bytes': '1234',
        'tx_bytes': 5678,
      });
      expect(net.uid, 10123);
      expect(net.rxBytes, 1234);
      expect(net.txBytes, 5678);

      final empty = PerfNetCounters.fromJson(const <String, dynamic>{});
      expect(empty.uid, isNull);
      expect(empty.rxBytes, isNull);
      expect(empty.txBytes, isNull);
    });

    test('PerfProcessInfo 解码 pid/ppid/rss_kb/name（ppid 缺省为 null）', () {
      final process = PerfProcessInfo.fromJson(<String, dynamic>{
        'pid': 4242,
        'ppid': 1000,
        'rss_kb': 204800,
        'name': 'com.example.app',
      });
      expect(process.pid, 4242);
      expect(process.ppid, 1000);
      expect(process.rssKb, 204800);
      expect(process.name, 'com.example.app');

      // 系统 perf.processes 无 ppid → null。
      expect(PerfProcessInfo.fromJson(const <String, dynamic>{}).ppid, isNull);
      expect(
        PerfProcessInfo.fromJson(<String, dynamic>{'pid': 1, 'name': 'x'}).ppid,
        isNull,
      );
    });

    test('PerfRenderBreakdown 宽容解码（含数字字符串 / 缺字段）', () {
      final render = PerfRenderBreakdown.fromJson(<String, dynamic>{
        'frame_count': 120,
        'fps': 58.5,
        'jank_count': 2,
        'avg_total_ms': 11.2,
        'p50_total_ms': '8.0',
        'p90_total_ms': 16.5,
        'p99_total_ms': 24.0,
        'avg_ui_ms': 5.1,
        'avg_draw_ms': 3.2,
        'avg_gpu_ms': 2.9,
      });
      expect(render.frameCount, 120);
      expect(render.fps, 58.5);
      expect(render.jankCount, 2);
      expect(render.avgTotalMs, 11.2);
      expect(render.p50TotalMs, 8.0);
      expect(render.p90TotalMs, 16.5);
      expect(render.p99TotalMs, 24.0);
      expect(render.avgUiMs, 5.1);
      expect(render.avgDrawMs, 3.2);
      expect(render.avgGpuMs, 2.9);

      final empty = PerfRenderBreakdown.fromJson(const <String, dynamic>{});
      expect(empty.frameCount, isNull);
      expect(empty.fps, isNull);
      expect(empty.jankCount, isNull);
      expect(empty.avgTotalMs, isNull);
      expect(empty.avgUiMs, isNull);
      expect(empty.avgGpuMs, isNull);
    });

    test('PerfPowerAttribution 宽容解码（含数字字符串 / 缺字段）', () {
      final power = PerfPowerAttribution.fromJson(<String, dynamic>{
        'mah': 3.42,
        'wake_lock_ms': 65000,
        'mobile_radio_mah': '0.8',
        'wifi_mah': 1.2,
        'screen_mah': 1.0,
        'cpu_mah': 0.42,
      });
      expect(power.mah, 3.42);
      expect(power.wakeLockMs, 65000);
      expect(power.mobileRadioMah, 0.8);
      expect(power.wifiMah, 1.2);
      expect(power.screenMah, 1.0);
      expect(power.cpuMah, 0.42);

      final empty = PerfPowerAttribution.fromJson(const <String, dynamic>{});
      expect(empty.mah, isNull);
      expect(empty.wakeLockMs, isNull);
      expect(empty.mobileRadioMah, isNull);
      expect(empty.cpuMah, isNull);
    });

    test('ThirdPartyAppMetrics 扩展字段解码 + 缺字段宽容', () {
      final metrics = ThirdPartyAppMetrics.fromJson(<String, dynamic>{
        'uid': 10123,
        'threads': 42,
        'mem_summary': <String, dynamic>{
          'java_heap_kb': 1,
          'native_heap_kb': 2,
        },
        'processes': <Map<String, dynamic>>[
          <String, dynamic>{
            'pid': 1,
            'ppid': 0,
            'rss_kb': 3,
            'name': 'a',
          },
        ],
        'net': <String, dynamic>{'uid': 10123, 'rx_bytes': 10, 'tx_bytes': 20},
        'render': <String, dynamic>{'fps': 60.0, 'jank_count': 1},
        'power': <String, dynamic>{'mah': 2.5, 'wake_lock_ms': 1000},
      });
      expect(metrics.uid, 10123);
      expect(metrics.threads, 42);
      expect(metrics.memSummary?.javaHeapKb, 1);
      expect(metrics.processes.single.ppid, 0);
      expect(metrics.net?.txBytes, 20);
      expect(metrics.render?.fps, 60.0);
      expect(metrics.render?.jankCount, 1);
      expect(metrics.power?.mah, 2.5);
      expect(metrics.power?.wakeLockMs, 1000);

      // 缺 render/power → null（非空默认）。
      final empty =
          ThirdPartyAppMetrics.fromJson(const <String, dynamic>{});
      expect(empty.uid, isNull);
      expect(empty.threads, isNull);
      expect(empty.memSummary, isNull);
      expect(empty.processes, isEmpty);
      expect(empty.net, isNull);
      expect(empty.render, isNull);
      expect(empty.power, isNull);
    });
  });

  group('sample()', () {
    test('执行全部命令、传原文给模块、返回扩展字段（uid/线程/内存细分/进程/网络/渲染/耗电）',
        () async {
      final recorder = _runner();
      final gateway = _FakePerfGateway();
      final service = ThirdPartyPerfService(
        runner: recorder.run,
        module: PerfModule(gateway: gateway),
      );

      final metrics = await service.sample('com.example.app');

      // pid 已知 → 额外采集 status；应用深入批次追加 4 条命令。
      // 采集器 ps 输出为 'ps text'（无有效进程行）→ 无 smaps cat 命令。
      expect(recorder.commands, <String>[
        'pidof com.example.app',
        'dumpsys cpuinfo',
        'dumpsys meminfo com.example.app',
        'dumpsys gfxinfo com.example.app',
        'dumpsys gfxinfo com.example.app framestats',
        'cmd package list packages -U',
        'ps -A',
        'cat /proc/4242/status',
        'dumpsys netstats detail',
        'dumpsys batterystats --charged com.example.app',
        'dumpsys package com.example.app',
        'dumpsys dropbox --print data_app_crash',
        'dumpsys dropbox --print data_app_anr',
        'dumpsys activity activities',
      ]);
      expect(metrics.cpuPercent, 25.5);
      expect(metrics.memPssKb, 204800);
      expect(metrics.jankyFrames, 3);
      expect(metrics.jankyPercent, 1.5);
      expect(metrics.pid, 4242);
      expect(metrics.uid, 10123);
      expect(metrics.threads, 42);
      expect(metrics.memSummary?.javaHeapKb, 81920);
      expect(metrics.memSummary?.totalPssKb, 204800);
      expect(metrics.processes, hasLength(1));
      expect(metrics.processes.single.ppid, 1000);
      expect(metrics.processes.single.rssKb, 204800);
      expect(metrics.net?.rxBytes, 1000);
      expect(metrics.net?.txBytes, 500);
      // 渲染细分 / 耗电归因透传。
      expect(metrics.render?.fps, 58.5);
      expect(metrics.render?.jankCount, 3);
      expect(metrics.render?.avgUiMs, 5.1);
      expect(metrics.render?.avgGpuMs, 2.9);
      expect(metrics.power?.mah, 3.42);
      expect(metrics.power?.wakeLockMs, 65000);
      expect(metrics.power?.cpuMah, 0.42);
      // 应用深入批次透传。
      expect(metrics.appInfo?.versionName, '9.1');
      expect(metrics.appInfo?.versionCode, 91);
      expect(metrics.appInfo?.targetSdk, 33);
      expect(metrics.appInfo?.requestedPermissions, hasLength(2));
      expect(metrics.appInfo?.grantedPermissions, hasLength(1));
      expect(metrics.appInfo?.activityCount, 5);
      expect(metrics.smaps?.pssKb, 204800);
      expect(metrics.smaps?.privateDirtyKb, 65536);
      expect(metrics.crashes?.crashCount, 2);
      expect(metrics.crashes?.anrCount, 1);
      expect(metrics.crashes?.recent, hasLength(2));
      expect(metrics.foreground?.isForeground, isTrue);
      expect(metrics.wakeLocks, hasLength(2));
      expect(metrics.wakeLocks.first.name, 'AudioMix');
      expect(metrics.wakeLocks.first.ms, 90000);
      // 首次采样无基线 → fps / 网络速率为 null。
      expect(metrics.fps, isNull);
      expect(metrics.rxBytesPerSec, isNull);
      expect(metrics.txBytesPerSec, isNull);

      // 载荷携带原始文本 + pid + uid。
      final payload = jsonDecode(utf8.decode(gateway.lastPayload!));
      expect(payload['package'], 'com.example.app');
      expect(payload['pid'], 4242);
      expect(payload['uid'], 10123);
      expect(payload['cpuinfo'], 'cpuinfo text');
      expect(payload['meminfo'], 'meminfo text');
      expect(payload['gfxinfo'], 'gfxinfo text');
      expect(payload['framestats'], 'framestats text');
      expect(payload['ps'], 'ps text');
      expect(payload['status'], 'Threads:\t42\n');
      expect(payload['netstats'], 'netstats text');
      expect(payload['batterystats'], 'batterystats text');
      expect(payload['package_info'], 'package text');
      // 采集器 ps 无有效进程行 → 未拼接 smaps（空串）。
      expect(payload['smaps'], '');
      expect(payload['crash_log'], 'crashlog text');
      expect(payload['anr_log'], 'anrlog text');
      expect(payload['activity'], 'activity text');
    });

    test('FPS 由 frame_count 差值推导：30 帧 / 1000ms → 30fps', () async {
      final recorder = _runner();
      // 两次调用返回 frame_count 100 → 130。
      final gateway = _FakePerfGateway(frameCounts: const [100, 130]);
      final times = <int>[1000, 2000];
      final service = ThirdPartyPerfService(
        runner: recorder.run,
        module: PerfModule(gateway: gateway),
        clock: () => DateTime.fromMillisecondsSinceEpoch(times.removeAt(0)),
      );

      final first = await service.sampleDetailed('com.example.app');
      expect(first.tsMs, 1000);
      expect(first.metrics.fps, isNull);

      final second = await service.sampleDetailed(
        'com.example.app',
        prevFrameCount: first.metrics.frameCount,
        prevTsMs: first.tsMs,
      );
      expect(second.tsMs, 2000);
      // (130 - 100) * 1000 / (2000 - 1000) = 30.0
      expect(second.metrics.fps, 30.0);
    });

    test('网络速率由 net 计数器差值推导（字节/秒）', () async {
      final recorder = _runner();
      final gateway = _FakePerfGateway(
        netRxs: const [1000, 3000],
        netTxs: const [500, 1500],
      );
      final times = <int>[1000, 2000];
      final service = ThirdPartyPerfService(
        runner: recorder.run,
        module: PerfModule(gateway: gateway),
        clock: () => DateTime.fromMillisecondsSinceEpoch(times.removeAt(0)),
      );

      final first = await service.sampleDetailed('com.example.app');
      expect(first.metrics.net?.rxBytes, 1000);
      expect(first.metrics.rxBytesPerSec, isNull);

      final second = await service.sampleDetailed(
        'com.example.app',
        prevTsMs: first.tsMs,
        prevRxBytes: first.metrics.net?.rxBytes,
        prevTxBytes: first.metrics.net?.txBytes,
      );
      // (3000-1000)*1000/1000 = 2000 B/s ; (1500-500)*1000/1000 = 1000 B/s
      expect(second.metrics.rxBytesPerSec, 2000.0);
      expect(second.metrics.txBytesPerSec, 1000.0);
    });

    test('网络计数器倒退（重置）→ 速率为 null，不抛', () async {
      final recorder = _runner();
      final gateway = _FakePerfGateway(
        netRxs: const [5000, 100],
        netTxs: const [5000, 100],
      );
      final times = <int>[1000, 2000];
      final service = ThirdPartyPerfService(
        runner: recorder.run,
        module: PerfModule(gateway: gateway),
        clock: () => DateTime.fromMillisecondsSinceEpoch(times.removeAt(0)),
      );

      final first = await service.sampleDetailed('com.example.app');
      final second = await service.sampleDetailed(
        'com.example.app',
        prevTsMs: first.tsMs,
        prevRxBytes: first.metrics.net?.rxBytes,
        prevTxBytes: first.metrics.net?.txBytes,
      );
      expect(second.metrics.rxBytesPerSec, isNull);
      expect(second.metrics.txBytesPerSec, isNull);
    });

    test('Shizuku 命令无输出 / 模块不可用 → 降级不抛异常', () async {
      final service = ThirdPartyPerfService(
        runner: (cmd) async => null,
        module: PerfModule(gateway: _FakePerfGateway(unavailable: true)),
      );

      final metrics = await service.sample('com.example.app');

      expect(metrics.running, isFalse);
      expect(metrics.cpuPercent, isNull);
      expect(metrics.pid, isNull);
      expect(metrics.fps, isNull);
    });
  });

  group('watch()', () {
    test('订阅即产出一条并可在首条后取消（无 pending timer）', () async {
      final recorder = _runner();
      final gateway = _FakePerfGateway(frameCounts: const [10, 20, 30]);
      final service = ThirdPartyPerfService(
        runner: recorder.run,
        module: PerfModule(gateway: gateway),
      );

      final first = await service
          .watch('com.example.app', interval: const Duration(milliseconds: 20))
          .first;
      expect(first.metrics.package, 'com.example.app');
      expect(first.metrics.cpuPercent, 25.5);
    });
  });

  group('Shizuku 可用性', () {
    test('binder 未运行 → binderUnavailable', () async {
      final service = ThirdPartyPerfService(
        shizukuApi: _FakeShizuku(binder: false),
        runner: (cmd) async => null,
      );
      expect(await service.ensureShizuku(), isFalse);
      expect(service.shizukuStatus, ShizukuStatus.binderUnavailable);
      expect(service.shizukuAvailable, isFalse);
    });

    test('未授权但可请求 → 授权成功 available', () async {
      final service = ThirdPartyPerfService(
        shizukuApi: _FakeShizuku(granted: false, grantOnRequest: true),
        runner: (cmd) async => null,
      );
      expect(await service.ensureShizuku(), isTrue);
      expect(service.shizukuStatus, ShizukuStatus.available);
      expect(service.shizukuAvailable, isTrue);
    });

    test('用户拒绝授权 → permissionDenied', () async {
      final service = ThirdPartyPerfService(
        shizukuApi: _FakeShizuku(granted: false, grantOnRequest: false),
        runner: (cmd) async => null,
      );
      expect(await service.ensureShizuku(), isFalse);
      expect(service.shizukuStatus, ShizukuStatus.permissionDenied);
    });

    test('refreshShizukuStatus 不请求授权（已授权即可用）', () async {
      final fake = _FakeShizuku(granted: false, grantOnRequest: true);
      final service = ThirdPartyPerfService(
        shizukuApi: fake,
        runner: (cmd) async => null,
      );
      expect(await service.refreshShizukuStatus(), isFalse);
      expect(service.shizukuStatus, ShizukuStatus.permissionDenied);
      // 未触发 requestPermission：granted 仍为 false。
      expect(fake.granted, isFalse);
    });
  });
}
