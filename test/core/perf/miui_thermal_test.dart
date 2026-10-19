import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/core/perf/miui_thermal.dart';

const String _bkDir = '/tmp/gstore_miui_thermal_backup';

/// 记录命令 + 维护内存文件系统的假 runner（**不触碰真实 Shizuku / 真机**）。
///
/// 依据命令内的特征子串分发；返回带哨兵行的合并输出（与 Rust 门面语义一致）。
class _FakeRunner {
  _FakeRunner({
    this.versionName = 'V816.0.1.0',
    this.versionCode = '14',
    this.unreachable = false,
    Map<String, String>? properties,
    Map<String, int>? sizes,
    this.ignoreWrites = const <String>{},
  })  : properties = properties ?? const <String, String>{},
        sizes = <String, int>{...?sizes};

  final String versionName;
  final String versionCode;
  final bool unreachable;
  final Map<String, String> properties;

  /// 内存文件大小表（存在即有大小）。
  final Map<String, int> sizes;

  /// 这些目标路径的写入「成功」但**不生效**（制造回读不一致）。
  final Set<String> ignoreWrites;

  final List<String> commands = <String>[];

  Future<String?> run(String command) async {
    commands.add(command);
    if (unreachable) return null;

    // 诊断：getprop | grep（先于单个 getprop 判定）
    if (command.contains('getprop | grep')) {
      final found = properties.entries
          .where((e) => e.key.toLowerCase().contains('thermal') ||
              e.key.toLowerCase().contains('miui'))
          .map((e) => '[${e.key}]: [${e.value}]')
          .join('\n');
      return found.isEmpty
          ? 'GSTORE_RESULT err=1'
          : '$found\nGSTORE_RESULT ok=1';
    }
    if (command.contains('getprop ro.miui.ui.version.name')) {
      return versionName.isEmpty
          ? 'GSTORE_RESULT ok=1'
          : '$versionName\nGSTORE_RESULT ok=1';
    }
    if (command.contains('getprop ro.miui.ui.version.code')) {
      return versionCode.isEmpty
          ? 'GSTORE_RESULT ok=1'
          : '$versionCode\nGSTORE_RESULT ok=1';
    }

    // 诊断：thermal zones / cooling
    if (command.contains('ls /sys/class/thermal | grep cooling_device')) {
      return 'cooling_device0\ncooling_device1\nGSTORE_RESULT ok=1';
    }
    if (command.contains('ls /sys/class/thermal')) {
      return 'cooling_device0\nthermal_zone0\nthermal_zone1\n'
          'GSTORE_RESULT ok=1';
    }

    // 备份（mkdir + cp）
    if (command.contains('mkdir -p') && command.contains('cp -f')) {
      final match = RegExp(r'cp -f (\S+) (\S+)').firstMatch(command);
      if (match == null) return 'GSTORE_RESULT err=1';
      final src = match.group(1)!;
      final dst = match.group(2)!;
      final size = sizes[src];
      if (size == null) return 'GSTORE_RESULT err=1';
      sizes[dst] = size;
      return 'GSTORE_RESULT ok=1';
    }
    // 恢复（仅 cp）
    if (command.contains('cp -f')) {
      final match = RegExp(r'cp -f (\S+) (\S+)').firstMatch(command);
      if (match == null) return 'GSTORE_RESULT err=1';
      final src = match.group(1)!;
      final dst = match.group(2)!;
      final size = sizes[src];
      if (size == null) return 'GSTORE_RESULT err=1';
      if (!ignoreWrites.contains(dst)) sizes[dst] = size;
      return 'GSTORE_RESULT ok=1';
    }

    // 大小：glob（stat -c %s_%n）先于单文件（stat -c %s）判定
    if (command.contains('stat -c %s_%n')) {
      final match = RegExp(r'stat -c %s_%n (\S+)').firstMatch(command);
      if (match == null) return 'GSTORE_RESULT err=1';
      final glob = match.group(1)!;
      final regex = _globToRegExp(glob);
      final matches = sizes.entries.where((e) => regex.hasMatch(e.key));
      if (matches.isEmpty) return 'GSTORE_RESULT err=1';
      final body =
          matches.map((e) => '${e.value}_${e.key}').join('\n');
      return '$body\nGSTORE_RESULT ok=1';
    }
    if (command.contains('stat -c %s ')) {
      final match = RegExp(r'stat -c %s (\S+)').firstMatch(command);
      if (match == null) return 'GSTORE_RESULT err=1';
      final path = match.group(1)!;
      final size = sizes[path];
      if (size == null) return 'GSTORE_RESULT err=1';
      return '$size\nGSTORE_RESULT ok=1';
    }

    return 'GSTORE_RESULT err=1';
  }

  static RegExp _globToRegExp(String pattern) {
    final buffer = StringBuffer('^');
    for (final rune in pattern.runes) {
      final ch = String.fromCharCode(rune);
      buffer.write(ch == '*' ? '[^/]*' : RegExp.escape(ch));
    }
    buffer.write(r'$');
    return RegExp(buffer.toString());
  }
}

MiuiThermalService _service(_FakeRunner runner) => MiuiThermalService(
      runner: runner.run,
      backupDir: _bkDir,
      clock: () => 1700000000000,
    );

const String _systemConf = '/system/etc/thermal_generic.conf';
const String _vendorConf = '/vendor/etc/thermal.conf';

void main() {
  group('MIUI 检测', () {
    test('ro.miui.ui.version.name 非空 → isMiui，显示 MIUI 版本', () async {
      final runner = _FakeRunner();
      final detection = await _service(runner).detect();
      expect(detection.isMiui, isTrue);
      expect(detection.reachable, isTrue);
      expect(detection.versionName, 'V816.0.1.0');
      expect(detection.versionCode, '14');
      expect(detection.display, contains('MIUI'));
    });

    test('属性为空 → 非 MIUI（display「非 MIUI」）', () async {
      final runner = _FakeRunner(versionName: '', versionCode: '');
      final detection = await _service(runner).detect();
      expect(detection.isMiui, isFalse);
      expect(detection.versionName, isNull);
      expect(detection.display, '非 MIUI');
    });

    test('runner 返回 null（Shizuku 不可达）→ reachable=false', () async {
      final runner = _FakeRunner(unreachable: true);
      final detection = await _service(runner).detect();
      expect(detection.reachable, isFalse);
      expect(detection.isMiui, isFalse);
    });
  });

  group('诊断（只读）', () {
    test('列出白名单内配置的存在性 / 大小', () async {
      final runner = _FakeRunner(sizes: <String, int>{
        _systemConf: 512,
        _vendorConf: 256,
        '/system/etc/passwd': 99, // 非白名单 → 不应出现
      });
      final diagnostic = await _service(runner).diagnose();

      final paths = diagnostic.configs.map((e) => e.path).toList();
      expect(paths, contains(_systemConf));
      expect(paths, contains(_vendorConf));
      expect(paths, isNot(contains('/system/etc/passwd')));
      expect(
        diagnostic.configs.firstWhere((e) => e.path == _systemConf).sizeBytes,
        512,
      );
      expect(diagnostic.zones, contains('thermal_zone0'));
      expect(diagnostic.coolingDevices, contains('cooling_device0'));
    });
  });

  group('备份门禁与命令序列', () {
    test('非白名单路径 → path_not_allowed 且零命令', () async {
      final runner = _FakeRunner();
      final result = await _service(runner).backup('/data/local/tmp/evil.conf');
      expect(result.ok, isFalse);
      expect(result.error, MiuiThermalError.pathNotAllowed);
      expect(runner.commands, isEmpty);
    });

    test('含危险字符的路径（注入尝试）→ 拒绝且零命令', () async {
      final runner = _FakeRunner();
      final result =
          await _service(runner).backup('/system/etc/thermal.conf; rm -rf /');
      expect(result.ok, isFalse);
      expect(result.error, MiuiThermalError.pathNotAllowed);
      expect(runner.commands, isEmpty);
    });

    test('合法路径 → mkdir+cp，生成正确备份记录，回读大小', () async {
      final runner = _FakeRunner(sizes: <String, int>{_systemConf: 512});
      final result = await _service(runner).backup(_systemConf);

      expect(result.ok, isTrue);
      final record = result.backup!;
      expect(record.sourcePath, _systemConf);
      expect(record.sizeBytes, 512);
      expect(record.createdAtMs, 1700000000000);
      expect(record.backupPath,
          '$_bkDir/1700000000000__%system%etc%thermal_generic.conf.bak');
      // 命令含 mkdir -p <dir> 且 cp -f <src> <dst>。
      final backupCmd = runner.commands.firstWhere((c) => c.contains('cp -f'));
      expect(backupCmd, contains('mkdir -p $_bkDir'));
      expect(backupCmd, contains('cp -f $_systemConf ${record.backupPath}'));
      // 自限时 + 哨兵链（绝不用 ; echo）。
      for (final command in runner.commands) {
        expect(command.startsWith('timeout '), isTrue);
        expect(command.contains('; echo'), isFalse);
      }
    });

    test('源文件不存在（cp 失败）→ command_failed', () async {
      final runner = _FakeRunner(sizes: <String, int>{});
      final result = await _service(runner).backup(_systemConf);
      expect(result.ok, isFalse);
      expect(result.error, MiuiThermalError.commandFailed);
    });
  });

  group('恢复门禁', () {
    MiuiThermalBackup record({String source = _systemConf}) =>
        MiuiThermalBackup(
          fileName: '1700000000000__x.bak',
          sourcePath: source,
          backupPath:
              '$_bkDir/1700000000000__%system%etc%thermal_generic.conf.bak',
          sizeBytes: 512,
          createdAtMs: 1700000000000,
        );

    test('缺少二次确认 → confirm_required 且零命令', () async {
      final runner = _FakeRunner(sizes: <String, int>{record().backupPath: 512});
      final result = await _service(runner).restore(record());
      expect(result.ok, isFalse);
      expect(result.error, MiuiThermalError.confirmRequired);
      expect(runner.commands, isEmpty);
    });

    test('恢复来源非本应用备份目录 → backup_not_owned', () async {
      final runner = _FakeRunner();
      final bad = MiuiThermalBackup(
        fileName: 'x.bak',
        sourcePath: _systemConf,
        backupPath: '/sdcard/x.bak',
        sizeBytes: 512,
        createdAtMs: 1,
      );
      final result = await _service(runner).restore(bad, confirmed: true);
      expect(result.ok, isFalse);
      expect(result.error, MiuiThermalError.backupNotOwned);
      expect(runner.commands, isEmpty);
    });

    test('恢复目标被篡改（非白名单）→ path_not_allowed', () async {
      final runner = _FakeRunner(sizes: <String, int>{record().backupPath: 512});
      final result = await _service(runner)
          .restore(record(source: '/data/local/tmp/evil.conf'), confirmed: true);
      expect(result.ok, isFalse);
      expect(result.error, MiuiThermalError.pathNotAllowed);
      expect(runner.commands, isEmpty);
    });

    test('备份文件不存在 → backup_not_found', () async {
      final runner = _FakeRunner(sizes: <String, int>{});
      final result = await _service(runner).restore(record(), confirmed: true);
      expect(result.ok, isFalse);
      expect(result.error, MiuiThermalError.backupNotFound);
    });

    test('确认 + 合法 → cp 回目标并回读校验通过', () async {
      final backupPath = record().backupPath;
      final runner = _FakeRunner(sizes: <String, int>{backupPath: 512});
      final result = await _service(runner).restore(record(), confirmed: true);

      expect(result.ok, isTrue);
      final cpCmd =
          runner.commands.firstWhere((c) => c.contains('cp -f'));
      expect(cpCmd, contains('cp -f $backupPath $_systemConf'));
      // 回读校验：目标大小 = 备份大小。
      expect(runner.sizes[_systemConf], 512);
    });

    test('回读不一致（写入未生效）→ read_back_mismatch', () async {
      final backupPath = record().backupPath;
      final runner = _FakeRunner(
        sizes: <String, int>{backupPath: 512, _systemConf: 999},
        ignoreWrites: <String>{_systemConf},
      );
      final result = await _service(runner).restore(record(), confirmed: true);
      expect(result.ok, isFalse);
      expect(result.error, MiuiThermalError.readBackMismatch);
    });
  });

  group('备份列表', () {
    test('仅列出可解码 + 白名单目标的记录，并按时间倒序', () async {
      final runner = _FakeRunner(sizes: <String, int>{
        '$_bkDir/1000__%system%etc%thermal_generic.conf.bak': 512,
        '$_bkDir/2000__%vendor%etc%thermal.conf.bak': 256,
        '$_bkDir/not-a-backup.txt': 1, // 形状不符 → 过滤
        '$_bkDir/3000__%data%local%tmp%evil.conf.bak': 8, // 目标非白名单 → 过滤
      });
      final backups = await _service(runner).listBackups();

      expect(backups, hasLength(2));
      expect(backups.first.createdAtMs, 2000);
      expect(backups.first.sourcePath, _vendorConf);
      expect(backups.last.sourcePath, _systemConf);
    });
  });
}
