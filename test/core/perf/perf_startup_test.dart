import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/core/perf/third_party_perf_service.dart';
import 'package:gstore/core/rust/perf/PerfContract.dart';
import 'package:gstore/core/rust/perf/PerfModule.dart';

/// 记录命令并返回罐头启动测量输出的 [CommandRunner]。
class _StartupRunner {
  _StartupRunner({this.resolveOutput});

  /// `cmd package resolve-activity --brief` 的输出（`null` → 解析失败）。
  final String? resolveOutput;

  /// `am start -W` 的固定输出。
  final String startOutput = 'am start text';

  final List<String> commands = <String>[];

  Future<String?> run(String command) async {
    commands.add(command);
    if (command.startsWith('cmd package resolve-activity')) return resolveOutput;
    if (command.startsWith('am force-stop')) return '';
    if (command.startsWith('am start -W')) return startOutput;
    if (command.startsWith('monkey')) return 'monkey output';
    return null;
  }
}

/// 假网关：仅处理 `perf.parse_startup`，返回固定 data（不触碰 FFI）。
class _StartupGateway implements PerfModuleGateway {
  _StartupGateway({
    this.data = const <String, dynamic>{},
    this.unavailable = false,
  });

  final Map<String, dynamic> data;
  final bool unavailable;
  String? lastMethod;
  Uint8List? lastPayload;

  @override
  Future<Uint8List> call(String method, [Uint8List? payload]) async {
    if (unavailable) throw PerfModuleUnavailableException();
    lastMethod = method;
    lastPayload = payload;
    return Uint8List.fromList(
      utf8.encode(
        jsonEncode(<String, dynamic>{'ok': true, 'data': data}),
      ),
    );
  }

  @override
  Stream<PerfRawEvent> get events => const Stream<PerfRawEvent>.empty();
}

const String _resolveOutput =
    'priority=0 preferredOrder=0 match=0x108000 specificIndex=-1 isDefault=false\n'
    '  com.example.app/.MainActivity\n';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PerfStartupResult 解码', () {
    test('解码完整 schema', () {
      final result = PerfStartupResult.fromJson(<String, dynamic>{
        'status': 'ok',
        'activity': 'com.example.app/.MainActivity',
        'this_time_ms': 800,
        'total_time_ms': 1234,
        'wait_time_ms': 1250,
        'mode': 'cold',
      });

      expect(result.status, 'ok');
      expect(result.activity, 'com.example.app/.MainActivity');
      expect(result.thisTimeMs, 800);
      expect(result.totalTimeMs, 1234);
      expect(result.waitTimeMs, 1250);
      expect(result.mode, 'cold');
      expect(result.ok, isTrue);
    });

    test('缺字段 / null / 数字字符串均宽容', () {
      final empty = PerfStartupResult.fromJson(const <String, dynamic>{});
      expect(empty.status, isNull);
      expect(empty.activity, isNull);
      expect(empty.thisTimeMs, isNull);
      expect(empty.totalTimeMs, isNull);
      expect(empty.waitTimeMs, isNull);
      expect(empty.mode, isNull);
      expect(empty.ok, isFalse);

      final coerced = PerfStartupResult.fromJson(<String, dynamic>{
        'this_time_ms': '800',
        'total_time_ms': 1234,
        'mode': 'warm',
      });
      expect(coerced.thisTimeMs, 800);
      expect(coerced.totalTimeMs, 1234);
      expect(coerced.waitTimeMs, isNull);
      expect(coerced.status, isNull);
      expect(coerced.mode, 'warm');
    });
  });

  group('PerfModule.parseStartup', () {
    test('已注册且 payload 使用 output / mode', () async {
      expect(PerfMethods.all, contains(PerfMethods.parseStartup));

      final gateway = _StartupGateway(
        data: <String, dynamic>{'status': 'ok', 'total_time_ms': 1234},
      );
      final module = PerfModule(gateway: gateway);

      final result = await module.parseStartup(output: 'am start text');

      expect(gateway.lastMethod, PerfMethods.parseStartup);
      final payload = jsonDecode(utf8.decode(gateway.lastPayload!));
      expect(payload['output'], 'am start text');
      // mode 缺省为 cold。
      expect(payload['mode'], 'cold');
      expect(result.totalTimeMs, 1234);
    });
  });

  group('measureStartup', () {
    test('冷启动：resolve-activity → force-stop → start -W，mode=cold', () async {
      final runner = _StartupRunner(resolveOutput: _resolveOutput);
      final gateway = _StartupGateway(
        data: <String, dynamic>{
          'status': 'ok',
          'activity': 'com.example.app/.MainActivity',
          'this_time_ms': 800,
          'total_time_ms': 1234,
          'wait_time_ms': 1250,
          'mode': 'cold',
        },
      );
      final service = ThirdPartyPerfService(
        runner: runner.run,
        module: PerfModule(gateway: gateway),
      );

      final result =
          await service.measureStartup('com.example.app', cold: true);

      expect(runner.commands, <String>[
        'cmd package resolve-activity --brief com.example.app',
        'am force-stop com.example.app',
        'am start -W -n com.example.app/.MainActivity',
      ]);
      expect(result?.status, 'ok');
      expect(result?.totalTimeMs, 1234);
      final payload = jsonDecode(utf8.decode(gateway.lastPayload!));
      expect(payload['output'], 'am start text');
      expect(payload['mode'], 'cold');
    });

    test('热启动：跳过 force-stop，mode=warm', () async {
      final runner = _StartupRunner(resolveOutput: _resolveOutput);
      final gateway = _StartupGateway(
        data: <String, dynamic>{'status': 'ok', 'mode': 'warm'},
      );
      final service = ThirdPartyPerfService(
        runner: runner.run,
        module: PerfModule(gateway: gateway),
      );

      final result =
          await service.measureStartup('com.example.app', cold: false);

      expect(runner.commands, <String>[
        'cmd package resolve-activity --brief com.example.app',
        'am start -W -n com.example.app/.MainActivity',
      ]);
      expect(result?.mode, 'warm');
      final payload = jsonDecode(utf8.decode(gateway.lastPayload!));
      expect(payload['mode'], 'warm');
    });

    test('activity 为全限定名时 -n 原样透传', () async {
      final runner = _StartupRunner(
        resolveOutput: 'com.example.app/com.example.app.SplashActivity\n',
      );
      final service = ThirdPartyPerfService(
        runner: runner.run,
        module: PerfModule(gateway: _StartupGateway()),
      );

      await service.measureStartup('com.example.app', cold: false);

      expect(
        runner.commands,
        contains('am start -W -n com.example.app/com.example.app.SplashActivity'),
      );
    });

    test('resolve-activity 失败 → 回退 monkey（冷启动仍先 force-stop）', () async {
      final runner = _StartupRunner(resolveOutput: null);
      final gateway = _StartupGateway();
      final service = ThirdPartyPerfService(
        runner: runner.run,
        module: PerfModule(gateway: gateway),
      );

      await service.measureStartup('com.example.app', cold: true);

      expect(runner.commands, <String>[
        'cmd package resolve-activity --brief com.example.app',
        'am force-stop com.example.app',
        'monkey -p com.example.app -c android.intent.category.LAUNCHER 1',
      ]);
      final payload = jsonDecode(utf8.decode(gateway.lastPayload!));
      expect(payload['output'], 'monkey output');
    });

    test('resolve-activity 输出不匹配包名 → 回退 monkey', () async {
      final runner = _StartupRunner(
        resolveOutput: 'com.other.app/.MainActivity\n',
      );
      final service = ThirdPartyPerfService(
        runner: runner.run,
        module: PerfModule(gateway: _StartupGateway()),
      );

      await service.measureStartup('com.example.app', cold: false);

      expect(
        runner.commands.last,
        'monkey -p com.example.app -c android.intent.category.LAUNCHER 1',
      );
    });

    test('模块不可用 → 返回 null，不抛异常', () async {
      final runner = _StartupRunner(resolveOutput: _resolveOutput);
      final service = ThirdPartyPerfService(
        runner: runner.run,
        module: PerfModule(gateway: _StartupGateway(unavailable: true)),
      );

      expect(
        await service.measureStartup('com.example.app', cold: true),
        isNull,
      );
    });

    test('命令全部无输出 → 降级但仍返回宽容结果（数值为 null）', () async {
      final service = ThirdPartyPerfService(
        runner: (cmd) async => null,
        module: PerfModule(gateway: _StartupGateway()),
      );

      final result =
          await service.measureStartup('com.example.app', cold: false);

      expect(result, isNotNull);
      expect(result!.status, isNull);
      expect(result.totalTimeMs, isNull);
      expect(result.waitTimeMs, isNull);
    });
  });
}
