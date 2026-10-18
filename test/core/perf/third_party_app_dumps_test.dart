import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/core/perf/third_party_perf_service.dart';
import 'package:gstore/core/rust/perf/PerfContract.dart';
import 'package:gstore/core/rust/perf/PerfModule.dart';

/// 假网关：返回固定「应用深入」JSON，记录最后一次 payload；**不触碰 FFI**。
class _EchoGateway implements PerfModuleGateway {
  Uint8List? lastPayload;

  @override
  Future<Uint8List> call(String method, [Uint8List? payload]) async {
    expect(method, PerfMethods.parseAppDumps);
    lastPayload = payload;
    return Uint8List.fromList(
      utf8.encode(
        jsonEncode(<String, dynamic>{
          'ok': true,
          'data': <String, dynamic>{
            'package': 'com.example.app',
            'app_info': <String, dynamic>{
              'version_name': '9.1',
              'version_code': 91,
              'target_sdk': 33,
              'min_sdk': 24,
              'first_install': '2023-05-01 12:34:56',
              'last_update': '2024-06-01 08:00:00',
              'code_path': '/data/app/com.example.app/base.apk',
              'data_dir': '/data/user/0/com.example.app',
              'is_system': true,
              'enabled': true,
              'requested_permissions': <String>['a', 'b', 'c'],
              'granted_permissions': <String>['a'],
              'activity_count': 5,
              'service_count': 3,
              'receiver_count': 2,
              'provider_count': 1,
            },
            'smaps': <String, dynamic>{
              'pss_kb': 307200,
              'rss_kb': 409600,
              'shared_clean_kb': 10240,
              'shared_dirty_kb': 2048,
              'private_clean_kb': 8192,
              'private_dirty_kb': 131072,
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
          },
        }),
      ),
    );
  }

  @override
  Stream<PerfRawEvent> get events => const Stream<PerfRawEvent>.empty();
}

/// 罐头命令执行器：返回真实 ps 表 + 两进程 smaps。
class _Runner {
  final List<String> commands = <String>[];

  Future<String?> run(String command) async {
    commands.add(command);
    if (command.startsWith('pidof')) return '4242 4243\n';
    if (command.startsWith('dumpsys cpuinfo')) return 'cpuinfo text';
    if (command.startsWith('dumpsys meminfo')) return 'meminfo text';
    if (command.startsWith('dumpsys gfxinfo') && command.endsWith('framestats')) {
      return 'framestats text';
    }
    if (command.startsWith('dumpsys gfxinfo')) return 'gfxinfo text';
    if (command.startsWith('cmd package list packages')) {
      return 'package:com.example.app uid:10123\n';
    }
    if (command.startsWith('ps -A')) {
      return 'USER PID PPID VSZ RSS WCHAN ADDR S NAME\n'
          'u0_a1 4242 1000 1 1 0 0 S com.example.app\n'
          'u0_a1 4243 1000 1 1 0 0 S com.example.app:service\n'
          'u0_a9 9999 1000 1 1 0 0 S com.other.app\n';
    }
    if (command.startsWith('cat /proc/4242/smaps_rollup')) {
      return 'Pss: 200000 kB\nRss: 300000 kB';
    }
    if (command.startsWith('cat /proc/4243/smaps_rollup')) {
      return 'Pss: 107200 kB';
    }
    if (command.startsWith('dumpsys package')) return 'package text';
    if (command.startsWith('dumpsys dropbox') &&
        command.contains('data_app_crash')) {
      return 'crash text';
    }
    if (command.startsWith('dumpsys dropbox')) return 'anr text';
    if (command.startsWith('dumpsys activity')) return 'activity text';
    return null;
  }
}

/// 无匹配进程的 runner：ps 只有表头与无关进程 → 不拼接 smaps。
class _NoPidRunner extends _Runner {
  @override
  Future<String?> run(String command) async {
    if (command.startsWith('ps -A')) {
      commands.add(command);
      return 'USER PID PPID VSZ RSS WCHAN ADDR S NAME\n'
          'u0_a9 9999 1000 1 1 0 0 S com.other.app\n';
    }
    return super.run(command);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PerfAppInfo 解码', () {
    test('完整 schema', () {
      final info = PerfAppInfo.fromJson(<String, dynamic>{
        'version_name': '9.1',
        'version_code': 91,
        'target_sdk': 33,
        'min_sdk': 24,
        'first_install': '2023-05-01 12:34:56',
        'last_update': '2024-06-01 08:00:00',
        'code_path': '/data/app/com.example.app/base.apk',
        'data_dir': '/data/user/0/com.example.app',
        'is_system': true,
        'enabled': true,
        'requested_permissions': <String>['a', 'b', 'c'],
        'granted_permissions': <String>['a'],
        'activity_count': 5,
        'service_count': 3,
        'receiver_count': 2,
        'provider_count': 1,
      });

      expect(info.versionName, '9.1');
      expect(info.versionCode, 91);
      expect(info.targetSdk, 33);
      expect(info.minSdk, 24);
      expect(info.firstInstall, '2023-05-01 12:34:56');
      expect(info.lastUpdate, '2024-06-01 08:00:00');
      expect(info.codePath, '/data/app/com.example.app/base.apk');
      expect(info.dataDir, '/data/user/0/com.example.app');
      expect(info.isSystem, isTrue);
      expect(info.enabled, isTrue);
      expect(info.requestedPermissions, hasLength(3));
      expect(info.grantedPermissions, hasLength(1));
      expect(info.activityCount, 5);
      expect(info.serviceCount, 3);
      expect(info.receiverCount, 2);
      expect(info.providerCount, 1);
      expect(info.grantRatio, closeTo(1 / 3, 1e-9));
    });

    test('缺字段 / null / 数字字符串均宽容', () {
      final empty = PerfAppInfo.fromJson(const <String, dynamic>{});
      expect(empty.versionName, isNull);
      expect(empty.versionCode, isNull);
      expect(empty.isSystem, isFalse);
      expect(empty.enabled, isFalse);
      expect(empty.requestedPermissions, isEmpty);
      expect(empty.grantedPermissions, isEmpty);
      expect(empty.activityCount, 0);
      expect(empty.grantRatio, isNull);

      final coerced = PerfAppInfo.fromJson(<String, dynamic>{
        'version_code': '91',
        'target_sdk': '33',
        'requested_permissions': 'not-a-list',
      });
      expect(coerced.versionCode, 91);
      expect(coerced.targetSdk, 33);
      expect(coerced.requestedPermissions, isEmpty);
    });
  });

  group('PerfSmaps 解码', () {
    test('完整 schema + 合计', () {
      final smaps = PerfSmaps.fromJson(<String, dynamic>{
        'pss_kb': 307200,
        'rss_kb': 409600,
        'shared_clean_kb': 10240,
        'shared_dirty_kb': 2048,
        'private_clean_kb': 8192,
        'private_dirty_kb': 131072,
      });
      expect(smaps.pssKb, 307200);
      expect(smaps.rssKb, 409600);
      expect(smaps.sharedCleanKb, 10240);
      expect(smaps.sharedDirtyKb, 2048);
      expect(smaps.privateCleanKb, 8192);
      expect(smaps.privateDirtyKb, 131072);
      expect(smaps.sharedKb, 12288);
      expect(smaps.privateKb, 139264);
    });

    test('缺字段宽容 + 合计边界', () {
      final empty = PerfSmaps.fromJson(const <String, dynamic>{});
      expect(empty.pssKb, isNull);
      expect(empty.rssKb, isNull);
      expect(empty.sharedKb, isNull);
      expect(empty.privateKb, isNull);

      // 仅一半存在时按 0 计另一半。
      final partial = PerfSmaps.fromJson(<String, dynamic>{
        'shared_clean_kb': '4096',
      });
      expect(partial.sharedCleanKb, 4096);
      expect(partial.sharedKb, 4096);
      expect(partial.privateKb, isNull);
    });
  });

  group('PerfCrashReport / PerfCrashEntry 解码', () {
    test('完整 schema', () {
      final report = PerfCrashReport.fromJson(<String, dynamic>{
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
      });
      expect(report.crashCount, 2);
      expect(report.anrCount, 1);
      expect(report.lastCrash, '2024-06-01 10:00:00');
      expect(report.lastAnr, '2024-06-02 11:00:00');
      expect(report.recent, hasLength(2));
      expect(report.recent.first.kind, 'crash');
      expect(report.recent.first.summary, 'java.lang.NullPointerException');
      expect(report.recent.last.kind, 'anr');
    });

    test('缺字段宽容 + 空 entry', () {
      final empty = PerfCrashReport.fromJson(const <String, dynamic>{});
      expect(empty.crashCount, 0);
      expect(empty.anrCount, 0);
      expect(empty.lastCrash, isNull);
      expect(empty.lastAnr, isNull);
      expect(empty.recent, isEmpty);

      final entry = PerfCrashEntry.fromJson(const <String, dynamic>{});
      expect(entry.kind, isNull);
      expect(entry.time, isNull);
      expect(entry.summary, isNull);
    });
  });

  group('PerfForeground 解码', () {
    test('true / false / 缺省', () {
      expect(
        PerfForeground.fromJson(<String, dynamic>{'is_foreground': true})
            .isForeground,
        isTrue,
      );
      expect(
        PerfForeground.fromJson(<String, dynamic>{'is_foreground': false})
            .isForeground,
        isFalse,
      );
      expect(
        PerfForeground.fromJson(const <String, dynamic>{}).isForeground,
        isFalse,
      );
    });
  });

  group('PerfWakeLock 解码', () {
    test('完整 + 缺字段', () {
      final lock = PerfWakeLock.fromJson(<String, dynamic>{
        'name': 'AudioMix',
        'ms': 90000,
      });
      expect(lock.name, 'AudioMix');
      expect(lock.ms, 90000);

      final empty = PerfWakeLock.fromJson(const <String, dynamic>{});
      expect(empty.name, isNull);
      expect(empty.ms, isNull);
    });
  });

  group('ThirdPartyAppMetrics 应用深入字段', () {
    test('解码 app_info / smaps / crashes / foreground / wake_locks', () {
      final metrics = ThirdPartyAppMetrics.fromJson(<String, dynamic>{
        'app_info': <String, dynamic>{'version_name': '9.1', 'is_system': true},
        'smaps': <String, dynamic>{'pss_kb': 307200},
        'crashes': <String, dynamic>{'crash_count': 2, 'anr_count': 1},
        'foreground': <String, dynamic>{'is_foreground': true},
        'wake_locks': <Map<String, dynamic>>[
          <String, dynamic>{'name': 'AudioMix', 'ms': 90000},
        ],
      });
      expect(metrics.appInfo?.versionName, '9.1');
      expect(metrics.appInfo?.isSystem, isTrue);
      expect(metrics.smaps?.pssKb, 307200);
      expect(metrics.crashes?.crashCount, 2);
      expect(metrics.foreground?.isForeground, isTrue);
      expect(metrics.wakeLocks.single.name, 'AudioMix');
    });

    test('缺字段 → null / 空列表', () {
      final empty = ThirdPartyAppMetrics.fromJson(const <String, dynamic>{});
      expect(empty.appInfo, isNull);
      expect(empty.smaps, isNull);
      expect(empty.crashes, isNull);
      expect(empty.foreground, isNull);
      expect(empty.wakeLocks, isEmpty);
    });

    test('withFps 透传应用深入字段（其余原样）', () {
      const original = ThirdPartyAppMetrics(
        package: 'com.example.app',
        appInfo: PerfAppInfo(versionName: '9.1', isSystem: true),
        smaps: PerfSmaps(pssKb: 307200),
        crashes: PerfCrashReport(crashCount: 2, anrCount: 1),
        foreground: PerfForeground(isForeground: true),
        wakeLocks: <PerfWakeLock>[PerfWakeLock(name: 'AudioMix', ms: 90000)],
      );
      final withFps = original.withFps(60.0, rxBytesPerSec: 1000);
      expect(withFps.fps, 60.0);
      expect(withFps.rxBytesPerSec, 1000);
      expect(withFps.appInfo?.versionName, '9.1');
      expect(withFps.smaps?.pssKb, 307200);
      expect(withFps.crashes?.anrCount, 1);
      expect(withFps.foreground?.isForeground, isTrue);
      expect(withFps.wakeLocks.single.name, 'AudioMix');
    });
  });

  group('服务采集应用深入（smaps 逐进程拼接）', () {
    test('ps 命中多进程 → 拼接各 smaps 并传入载荷；字段透传', () async {
      final runner = _Runner();
      final gateway = _EchoGateway();
      final service = ThirdPartyPerfService(
        runner: runner.run,
        module: PerfModule(gateway: gateway),
      );

      final metrics = await service.sample('com.example.app');

      // 逐进程 smaps 命令（按 ps 出现顺序）。
      expect(
        runner.commands,
        containsAllInOrder(<String>[
          'ps -A',
          'cat /proc/4242/status',
          'dumpsys netstats detail',
          'dumpsys batterystats --charged com.example.app',
          'dumpsys package com.example.app',
          'cat /proc/4242/smaps_rollup',
          'cat /proc/4243/smaps_rollup',
          'dumpsys dropbox --print data_app_crash',
          'dumpsys dropbox --print data_app_anr',
          'dumpsys activity activities',
        ]),
      );

      final payload = jsonDecode(utf8.decode(gateway.lastPayload!));
      expect(payload['package_info'], 'package text');
      expect(
        payload['smaps'],
        'Pss: 200000 kB\nRss: 300000 kB\nPss: 107200 kB',
      );
      expect(payload['crash_log'], 'crash text');
      expect(payload['anr_log'], 'anr text');
      expect(payload['activity'], 'activity text');

      // 响应字段透传。
      expect(metrics.appInfo?.versionName, '9.1');
      expect(metrics.appInfo?.grantRatio, closeTo(1 / 3, 1e-9));
      expect(metrics.smaps?.privateDirtyKb, 131072);
      expect(metrics.crashes?.recent, hasLength(2));
      expect(metrics.foreground?.isForeground, isTrue);
      expect(metrics.wakeLocks, hasLength(2));
      expect(metrics.wakeLocks.first.ms, 90000);
    });

    test('ps 无匹配进程 → 跳过 smaps（不执行 cat，载荷为空串）', () async {
      final runner = _NoPidRunner();
      final gateway = _EchoGateway();
      final service = ThirdPartyPerfService(
        runner: runner.run,
        module: PerfModule(gateway: gateway),
      );

      await service.sample('com.example.app');

      expect(
        runner.commands.where((c) => c.contains('smaps_rollup')),
        isEmpty,
      );
      final payload = jsonDecode(utf8.decode(gateway.lastPayload!));
      expect(payload['smaps'], '');
      expect(payload['package_info'], 'package text');
    });
  });
}
