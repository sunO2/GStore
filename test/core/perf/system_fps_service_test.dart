import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/core/perf/system_fps_service.dart';

/// 记录命令并返回罐头输出的假 [CommandRunner]（**不触碰真实 Shizuku**）。
class _RecordingRunner {
  _RecordingRunner(this._responder);

  final Future<String?> Function(String command) _responder;
  final List<String> commands = <String>[];

  Future<String?> run(String command) {
    commands.add(command);
    return _responder(command);
  }
}

/// 多层 `--timestats` 罐头输出：含黑名单层、SurfaceView/BLAST 层、普通层，
/// 其中黑名单层（Wallpaper 900）与普通层（plain 5000）的 totalFrames 都更高，
/// 用于验证「先过滤黑名单 → 优先 SurfaceView/BLAST → 再取 totalFrames 最大」。
String _multiLayerOutput() => '''
displayRefreshRate = 120 fps
renderRate = 120 fps

layerName = StatusBar#0
uid = 1000
totalFrames = 500
averageFPS = 30.0

layerName = NavigationBar0#0
uid = 1000
totalFrames = 400
averageFPS = 30.0

layerName = Wallpaper#0
totalFrames = 900
averageFPS = 10.0

layerName = Background for SurfaceView[com.example.app]#0
totalFrames = 800
averageFPS = 12.0

layerName = SurfaceView[com.example.app/com.example.app.Main]#0(BLAST)
uid = 10123
totalFrames = 274
displayRefreshRate = 120 fps
presentToPresent histogram is as below:
2ms=1
8ms=190
16ms=83
averageFPS = 120.569

layerName = com.example.other/com.example.other.Main#1(BLAST)
uid = 10124
totalFrames = 100
averageFPS = 90.0

layerName = com.example.plain/com.example.plain.Main#2
uid = 10125
totalFrames = 5000
averageFPS = 55.0
''';

/// 有效 `--latency` 罐头：3 个有效帧（乱序）+ 1 个 `0` + 1 个 INT64_MAX。
/// 时间戳 ns：1_000_000_000 / 1_020_000_000 / 1_040_000_000 → 跨度 4e7ns。
/// 期望 fps = (3-1)*1e9/4e7 = 50；平均间隔 = 4e7/2/1e6 = 20ms。
String _latencyOutput() => '16666666\n'
    '0\t0\t0\n'
    '1000000000\t1000000000\t1000000000\n'
    '9223372036854775807\t9223372036854775807\t9223372036854775807\n'
    '1040000000\t1040000000\t1040000000\n'
    '1020000000\t1020000000\t1020000000\n';

void main() {
  group('SystemFpsService.sample 选层', () {
    test('多层：过滤黑名单 → 优先 SurfaceView/BLAST → totalFrames 最大', () async {
      final runner = _RecordingRunner((_) async => _multiLayerOutput());
      final service = SystemFpsService(runner: runner.run);

      final sample = await service.sample();

      expect(sample, isNotNull);
      expect(sample!.fps, closeTo(120.0, 1e-9));
      expect(sample.layer, contains('SurfaceView'));
      expect(sample.layer, contains('BLAST'));
      expect(sample.totalFrames, 274);
      expect(sample.displayRefreshRate, closeTo(120.0, 1e-9));
      expect(sample.source, 'timestats');
      // 罐头输出无 `mCurrentFocus` / `topResumedActivity` → 前景探测失败 →
      // 直接回退 timestats；命令序列为两次前景探测 + 一次 timestats。
      expect(
        runner.commands,
        <String>[
          SystemFpsService.foregroundCommand,
          SystemFpsService.activityCommand,
          SystemFpsService.sampleCommand,
        ],
      );
    });

    test('无偏好层时退回全体候选取 totalFrames 最大', () async {
      const output = '''
layerName = com.example.a/A#0
totalFrames = 30
averageFPS = 30.0

layerName = com.example.b/B#0
totalFrames = 300
averageFPS = 45.0
''';
      final service = SystemFpsService(runner: (_) async => output);

      final sample = await service.sample();

      expect(sample, isNotNull);
      expect(sample!.layer, 'com.example.b/B#0');
      expect(sample.fps, closeTo(45.0, 1e-9));
      expect(sample.totalFrames, 300);
    });

    test('层块之间无空行（连续 layout）也能正确分层', () async {
      const output = 'layerName = A#0\n'
          'totalFrames = 10\n'
          'averageFPS = 20.0\n'
          'layerName = SurfaceView[x/y]#0(BLAST)\n'
          'totalFrames = 20\n'
          'averageFPS = 90.0\n';
      final service = SystemFpsService(runner: (_) async => output);

      final sample = await service.sample();

      expect(sample, isNotNull);
      expect(sample!.layer, contains('SurfaceView'));
      expect(sample.fps, closeTo(90.0, 1e-9));
    });

    test('注入时钟 → tsMs 采用该时钟', () async {
      final fixed = DateTime.fromMillisecondsSinceEpoch(1700000000000);
      final service = SystemFpsService(
        runner: (_) async => _multiLayerOutput(),
        clock: () => fixed,
      );

      final sample = await service.sample();

      expect(sample!.tsMs, 1700000000000);
    });
  });

  group('SystemFpsService.sample 降级（绝不抛）', () {
    test('命令返回 null → null', () async {
      final service = SystemFpsService(runner: (_) async => null);
      expect(await service.sample(), isNull);
    });

    test('空输出 → null', () async {
      final service = SystemFpsService(runner: (_) async => '   \n  ');
      expect(await service.sample(), isNull);
    });

    test('无 averageFPS 行 → null', () async {
      const output = 'layerName = SurfaceView[a/b]#0(BLAST)\n'
          'totalFrames = 100\n'
          'displayRefreshRate = 120 fps\n';
      final service = SystemFpsService(runner: (_) async => output);
      expect(await service.sample(), isNull);
    });

    test('仅黑名单层 → null', () async {
      const output = 'layerName = Wallpaper#0\n'
          'totalFrames = 900\n'
          'averageFPS = 10.0\n';
      final service = SystemFpsService(runner: (_) async => output);
      expect(await service.sample(), isNull);
    });

    test('averageFPS 非有限值（nan）→ null', () async {
      const output = 'layerName = SurfaceView[a/b]#0(BLAST)\n'
          'totalFrames = 10\n'
          'averageFPS = nan\n';
      final service = SystemFpsService(runner: (_) async => output);
      expect(await service.sample(), isNull);
    });

    test('runner 抛异常 → null（不冒泡）', () async {
      final service = SystemFpsService(
        runner: (_) async => throw StateError('boom'),
      );
      expect(await service.sample(), isNull);
    });
  });

  group('SystemFpsService enable / disable', () {
    test('enable 执行 -clear -enable 命令（失败静默）', () async {
      final runner = _RecordingRunner((_) async => '');
      final service = SystemFpsService(runner: runner.run);

      await service.enable();

      expect(runner.commands, <String>[SystemFpsService.enableCommand]);
    });

    test('disable 执行 -disable 命令', () async {
      final runner = _RecordingRunner((_) async => '');
      final service = SystemFpsService(runner: runner.run);

      await service.disable();

      expect(runner.commands, <String>[SystemFpsService.disableCommand]);
    });

    test('runner 抛异常时 enable / disable 不冒泡', () async {
      final service = SystemFpsService(
        runner: (_) async => throw StateError('boom'),
      );

      await expectLater(service.enable(), completes);
      await expectLater(service.disable(), completes);
    });
  });

  // ==================== a) 硬编码映射候选 ====================
  group('SystemFpsService.layerCandidatesFor 硬编码映射', () {
    test('sgame → SurfaceView - 映射层优先', () {
      final candidates = SystemFpsService.layerCandidatesFor(
        pkg: 'com.tencent.tmgp.sgame',
        activity: 'com.tencent.tmgp.sgame.SGameActivity',
      );
      expect(
        candidates.first,
        'SurfaceView - com.tencent.tmgp.sgame/'
        'com.tencent.tmgp.sgame.SGameActivity#0',
      );
    });

    test('原神 → SurfaceView - 映射层优先（映射 activity）', () {
      final candidates = SystemFpsService.layerCandidatesFor(
        pkg: 'com.miHoYo.Yuanshen',
        activity: 'com.miHoYo.Yuanshen/.MainActivity',
      );
      expect(
        candidates.first,
        'SurfaceView - com.miHoYo.Yuanshen/'
        'com.miHoYo.GetMobileInfo.MainActivity#0',
      );
    });

    test('通用候选含 3 种形态且去重（相对 activity 补全）', () {
      final candidates = SystemFpsService.layerCandidatesFor(
        pkg: 'com.example.app',
        activity: '.Main',
      );
      expect(candidates, contains('com.example.app/com.example.app.Main#0'));
      expect(
        candidates,
        contains('SurfaceView[com.example.app/com.example.app.Main]#0'),
      );
      expect(
        candidates,
        contains('SurfaceView - com.example.app/com.example.app.Main#0'),
      );
      expect(candidates.toSet().length, candidates.length);
    });

    test('浏览器白名单命中 → 含 SurfaceView - 层', () {
      final candidates = SystemFpsService.layerCandidatesFor(
        pkg: 'com.android.chrome',
        activity: 'com.google.android.apps.chrome.Main',
      );
      expect(
        candidates,
        contains(
          'SurfaceView - com.android.chrome/'
          'com.google.android.apps.chrome.Main#0',
        ),
      );
    });
  });

  // ==================== b) --list RequestedLayerState 剥离与匹配 ====================
  group('SystemFpsService.layerCandidatesFor --list 匹配', () {
    test('剥离 RequestedLayerState{} 外壳，匹配 pkg，SurfaceView/BLAST 优先', () {
      const listOutput = 'RequestedLayerState{SurfaceView[com.example.app/'
          'com.example.app.Main]#0(BLAST) id=5 parentId=0 z=10}\n'
          'RequestedLayerState{com.example.app/com.example.app.Main#0 id=6}\n'
          'StatusBar#0\n'
          'RequestedLayerState{Background for SurfaceView[com.example.app]#0 id=7}\n';

      final candidates = SystemFpsService.layerCandidatesFor(
        pkg: 'com.example.app',
        activity: 'com.example.app.Main',
        listOutput: listOutput,
      );

      expect(
        candidates,
        contains(
          'SurfaceView[com.example.app/com.example.app.Main]#0(BLAST)',
        ),
      );
      expect(
        candidates,
        contains('com.example.app/com.example.app.Main#0'),
      );
      expect(candidates, isNot(contains('StatusBar#0')));
      // --list 匹配项排在通用候选之后。
      expect(
        candidates.indexOf('SurfaceView[com.example.app/com.example.app.Main]#0(BLAST)'),
        greaterThan(
          candidates.indexOf('SurfaceView - com.example.app/com.example.app.Main#0'),
        ),
      );
    });

    test('支持 name= 字段形式', () {
      const listOutput = 'RequestedLayerState{id=9 parentId=0 z=3 '
          'name=SurfaceView[com.example.app/com.example.app.Main]#0(BLAST) '
          'flags=0}\n';
      final candidates = SystemFpsService.layerCandidatesFor(
        pkg: 'com.example.app',
        activity: 'com.example.app.Main',
        listOutput: listOutput,
      );
      expect(
        candidates,
        contains(
          'SurfaceView[com.example.app/com.example.app.Main]#0(BLAST)',
        ),
      );
    });
  });

  // ==================== c) --latency 3 列解析 ====================
  group('SystemFpsService.parseLatency', () {
    test('3 列解析：滤 0/INT64_MAX、排序、fps 与平均间隔公式', () {
      final stats = SystemFpsService.parseLatency(_latencyOutput());

      expect(stats, isNotNull);
      expect(stats!.frameCount, 3);
      expect(stats.fps, closeTo(50.0, 1e-9));
      expect(stats.avgFrameIntervalMs, closeTo(20.0, 1e-9));
      expect(stats.refreshPeriodNs, 16666666);
      expect(stats.displayRefreshRate, closeTo(1e9 / 16666666, 1e-6));
    });

    test('取第 2 列 actualPresentTime 而非第 1/3 列', () {
      // 首列/末列恒为常量，仅第 2 列变化 → fps 由第 2 列决定。
      // 周期取 240Hz（4166666ns）：原始 200fps 低于面板率，避免被钳制。
      const output = '4166666\n'
          '1\t1000000000\t2\n'
          '1\t1005000000\t2\n'
          '1\t1010000000\t2\n';
      final stats = SystemFpsService.parseLatency(output);
      expect(stats, isNotNull);
      // span = 1e7 ns, n=3 → fps = 2e9/1e7 = 200。
      expect(stats!.fps, closeTo(200.0, 1e-9));
    });
  });

  // ==================== d) <2 有效帧 → null ====================
  group('SystemFpsService.parseLatency 降级', () {
    test('仅 1 个有效帧 → null', () {
      expect(
        SystemFpsService.parseLatency(
          '16666666\n0\t0\t0\n1000000000\t1000000000\t1000000000\n',
        ),
        isNull,
      );
    });

    test('全部为 0 / INT64_MAX → null', () {
      expect(
        SystemFpsService.parseLatency(
          '16666666\n'
          '0\t0\t0\n'
          '9223372036854775807\t9223372036854775807\t9223372036854775807\n',
        ),
        isNull,
      );
    });

    test('跨度 ≤0（全部相同时间戳）→ null', () {
      expect(
        SystemFpsService.parseLatency(
          '16666666\n'
          '5\t1000000000\t5\n'
          '9\t1000000000\t9\n',
        ),
        isNull,
      );
    });
  });

  // ==================== e) 空输出 / 异常 → null ====================
  group('SystemFpsService.parseLatency 空输入', () {
    test('null → null', () {
      expect(SystemFpsService.parseLatency(null), isNull);
    });

    test('空白 → null', () {
      expect(SystemFpsService.parseLatency('   \n  '), isNull);
    });
  });

  // ==================== f) 前景包解析 ====================
  group('SystemFpsService.parseForeground', () {
    test('mCurrentFocus 全名 activity', () {
      const output = 'mCurrentFocus=Window{abc123 u0 com.tencent.tmgp.sgame/'
          'com.tencent.tmgp.sgame.SGameActivity}\n'
          'mFocusedApp=AppWindowToken{def}\n';
      final fg = SystemFpsService.parseForeground(output);
      expect(fg, isNotNull);
      expect(fg!.pkg, 'com.tencent.tmgp.sgame');
      expect(fg.activity, 'com.tencent.tmgp.sgame.SGameActivity');
    });

    test('topResumedActivity 相对 activity', () {
      const output = 'topResumedActivity=ActivityRecord{123 u0 '
          'com.miHoYo.Yuanshen/.MainActivity t5}\n';
      final fg = SystemFpsService.parseForeground(output);
      expect(fg, isNotNull);
      expect(fg!.pkg, 'com.miHoYo.Yuanshen');
      expect(fg.activity, '.MainActivity');
    });

    test('mCurrentFocus=null → null', () {
      expect(
        SystemFpsService.parseForeground('mCurrentFocus=null\n'),
        isNull,
      );
    });

    test('两个不同组件（歧义）→ null', () {
      const output = 'mCurrentFocus=Window{x u0 com.example.a/.A}\n'
          'topResumedActivity=ActivityRecord{y u0 com.example.b/.B t1}\n';
      expect(SystemFpsService.parseForeground(output), isNull);
    });

    test('无焦点行 → null', () {
      expect(SystemFpsService.parseForeground('random text\n'), isNull);
    });
  });

  // ==================== 端到端：latency 主路 + 回退 ====================
  group('SystemFpsService.sample latency 主路', () {
    test('前景 + 候选 → --latency 成功 → source=latency', () async {
      final runner = _RecordingRunner((command) async {
        if (command == SystemFpsService.foregroundCommand) {
          return 'mCurrentFocus=Window{x u0 com.example.app/'
              'com.example.app.Main}\n';
        }
        if (command == SystemFpsService.layerListCommand) {
          return 'com.example.app/com.example.app.Main#0\n';
        }
        if (command.startsWith('dumpsys SurfaceFlinger --latency')) {
          return _latencyOutput();
        }
        return null;
      });
      final service = SystemFpsService(runner: runner.run);

      final sample = await service.sample();

      expect(sample, isNotNull);
      expect(sample!.source, 'latency');
      expect(sample.fps, closeTo(50.0, 1e-9));
      expect(sample.avgFrameIntervalMs, closeTo(20.0, 1e-9));
      expect(sample.totalFrames, 3);
      expect(sample.layer, isNotEmpty);
      // 未走 timestats 回退。
      expect(runner.commands, isNot(contains(SystemFpsService.sampleCommand)));
      // 命令已对候选 layer 做单引号安全引用。
      expect(
        runner.commands.any(
          (c) => c.contains('--latency \'') && c.contains('\''),
        ),
        isTrue,
      );
    });

    test('含空格的硬编码候选被单引号包裹', () async {
      final runner = _RecordingRunner((command) async {
        if (command == SystemFpsService.foregroundCommand) {
          return 'mCurrentFocus=Window{x u0 com.tencent.tmgp.sgame/'
              'com.tencent.tmgp.sgame.SGameActivity}\n';
        }
        if (command == SystemFpsService.layerListCommand) return '';
        if (command.startsWith('dumpsys SurfaceFlinger --latency')) {
          return _latencyOutput();
        }
        return null;
      });
      final service = SystemFpsService(runner: runner.run);

      await service.sample();

      expect(
        runner.commands,
        contains(
          "dumpsys SurfaceFlinger --latency 'SurfaceView - "
          "com.tencent.tmgp.sgame/com.tencent.tmgp.sgame.SGameActivity#0'",
        ),
      );
    });

    test('latency 有效帧 <2 → 回退 timestats', () async {
      final runner = _RecordingRunner((command) async {
        if (command == SystemFpsService.foregroundCommand) {
          return 'mCurrentFocus=Window{x u0 com.example.app/'
              'com.example.app.Main}\n';
        }
        if (command == SystemFpsService.layerListCommand) return '';
        if (command.startsWith('dumpsys SurfaceFlinger --latency')) {
          return '16666666\n0\t0\t0\n'; // <2 有效帧
        }
        if (command == SystemFpsService.sampleCommand) {
          return _multiLayerOutput();
        }
        return null;
      });
      final service = SystemFpsService(runner: runner.run);

      final sample = await service.sample();

      expect(sample, isNotNull);
      expect(sample!.source, 'timestats');
      expect(sample.fps, closeTo(120.0, 1e-9));
      expect(runner.commands, contains(SystemFpsService.sampleCommand));
    });

    test('前景探测抛异常 → 回退 timestats（不冒泡）', () async {
      final runner = _RecordingRunner((command) async {
        if (command == SystemFpsService.foregroundCommand ||
            command == SystemFpsService.activityCommand) {
          throw StateError('probe boom');
        }
        if (command == SystemFpsService.sampleCommand) {
          return _multiLayerOutput();
        }
        return null;
      });
      final service = SystemFpsService(runner: runner.run);

      final sample = await service.sample();

      expect(sample, isNotNull);
      expect(sample!.source, 'timestats');
    });
  });

  // ==================== shell 引用 ====================
  group('SystemFpsService.shellQuote', () {
    test('空格/括号/# 被单引号包裹', () {
      expect(
        SystemFpsService.shellQuote('SurfaceView[x/y]#0(BLAST)'),
        "'SurfaceView[x/y]#0(BLAST)'",
      );
      expect(
        SystemFpsService.shellQuote("a'b"),
        "'a'\\''b'",
      );
    });
  });

  // ==================== FPS 面板率钳制（>120 伪影修复） ====================
  group('FPS 面板率钳制', () {
    test('clampFps：面板率已知钳制到面板率，未知用 240 上限', () {
      expect(SystemFpsService.clampFps(125.0, 120.0), 120.0);
      expect(SystemFpsService.clampFps(120.0, 120.0), 120.0);
      expect(SystemFpsService.clampFps(60.0, 120.0), 60.0);
      expect(SystemFpsService.clampFps(999.0, null), 240.0);
      expect(SystemFpsService.clampFps(-1, 120), 0);
    });

    test('parseLatency：短跨度原始 200fps 被钳制到面板率 120', () {
      const output = '8333333\n'
          '1000000000\t1000000000\t1000000000\n'
          '1005000000\t1005000000\t1005000000\n';
      final stats = SystemFpsService.parseLatency(output);
      expect(stats, isNotNull);
      expect(stats!.fps, closeTo(1e9 / 8333333, 1e-6));
      expect(stats.frameCount, 2);
    });

    test('timestats averageFPS=125 → 按 displayRefreshRate=120 钳制', () async {
      final runner = _RecordingRunner((command) async {
        if (command == SystemFpsService.sampleCommand) {
          return 'displayRefreshRate = 120 fps\n'
              'layerName = SurfaceView[com.example.app/com.example.app.Main]#0(BLAST)\n'
              'totalFrames = 100\n'
              'averageFPS = 125.0\n';
        }
        return null;
      });
      final service = SystemFpsService(runner: runner.run);

      final sample = await service.sample();

      expect(sample, isNotNull);
      expect(sample!.source, 'timestats');
      expect(sample.fps, closeTo(120.0, 1e-9));
    });
  });

  // ==================== 全局 FPS 兜底（Scene 8 FpsUtils 同源） ====================
  group('全局 FPS 兜底', () {
    test('measured_fps：命中即返回 fps（source=measured_fps）', () async {
      final runner = _RecordingRunner((command) async {
        if (command == 'cat /sys/class/drm/sde-crtc-0/measured_fps') {
          return '60';
        }
        return null;
      });
      final service = SystemFpsService(runner: runner.run);

      final sample = await service.sample();

      expect(sample, isNotNull);
      expect(sample!.source, 'measured_fps');
      expect(sample.fps, closeTo(60.0, 1e-9));
    });

    test('fpsgo_status：解析 currentFPS 列（source=fpsgo）', () async {
      final runner = _RecordingRunner((command) async {
        if (command == 'cat ${SystemFpsService.fpsgoStatusPath}') {
          return 'tid currentFPS fps\n1 120 120\n';
        }
        return null;
      });
      final service = SystemFpsService(runner: runner.run);

      final sample = await service.sample();

      expect(sample, isNotNull);
      expect(sample!.source, 'fpsgo');
      expect(sample.fps, closeTo(120.0, 1e-9));
    });

    test('SurfaceFlinger 1013：首样本建基线，次样本按差值算 FPS', () async {
      var now = 1000;
      var flipCall = 0;
      final runner = _RecordingRunner((command) async {
        if (command == SystemFpsService.pageFlipCommand) {
          flipCall++;
          return flipCall == 1
              ? "Result: Parcel(0000000a    '....')"
              : "Result: Parcel(0000003c    '....')";
        }
        return null;
      });
      final service = SystemFpsService(
        runner: runner.run,
        clock: () => DateTime.fromMillisecondsSinceEpoch(now),
      );

      final first = await service.sample();
      expect(first, isNull); // 首个样本仅建基线。

      now = 2000;
      final second = await service.sample();
      expect(second, isNotNull);
      expect(second!.source, 'surfaceflinger_1013');
      expect(second.fps, closeTo(50.0, 1e-9));
    });

    test('全部兜底不可用 → null（绝不抛）', () async {
      final runner = _RecordingRunner((command) async => null);
      final service = SystemFpsService(runner: runner.run);

      expect(await service.sample(), isNull);
    });
  });
}
