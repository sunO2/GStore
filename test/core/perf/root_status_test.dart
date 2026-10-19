import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/core/perf/miui_thermal.dart';
import 'package:gstore/core/perf/root_status.dart';

const String _bkDir = '/tmp/gstore_root_gate_backup';
const String _targetConf = '/system/etc/thermal_generic.conf';

/// 记录命令的假 runner（**不触碰真实 Shizuku / Root / 真机**）。
///
/// * `id -u`（Root 探测）→ [rootUid] 为 `null` 时回 `err`（无 Root）；
/// * `cp -f` / `stat -c %s`（备份 / 恢复 / 直写）→ 维护内存大小表。
class _FakeRunner {
  _FakeRunner({
    this.rootUid,
    this.unreachable = false,
    Map<String, int>? sizes,
    this.ignoreWrites = const <String>{},
  }) : sizes = <String, int>{...?sizes};

  /// Root uid；`null` = 无 Root（探测失败）。
  final String? rootUid;
  final bool unreachable;
  final Map<String, int> sizes;
  final Set<String> ignoreWrites;
  final List<String> commands = <String>[];

  Future<String?> run(String command) async {
    commands.add(command);
    if (unreachable) return null;

    if (command.contains('id -u')) {
      final uid = rootUid;
      return uid == null
          ? 'GSTORE_RESULT err=1'
          : '$uid\nGSTORE_RESULT ok=1';
    }
    if (command.contains('cp -f')) {
      final match =
          RegExp(r"cp -f ([^'\s]+) ([^'\s]+)").firstMatch(command);
      if (match == null) return 'GSTORE_RESULT err=1';
      final src = match.group(1)!;
      final dst = match.group(2)!;
      final size = sizes[src];
      if (size == null) return 'GSTORE_RESULT err=1';
      if (!ignoreWrites.contains(dst)) sizes[dst] = size;
      return 'GSTORE_RESULT ok=1';
    }
    if (command.contains('stat -c %s ')) {
      final match = RegExp(r"stat -c %s ([^'\s]+)").firstMatch(command);
      if (match == null) return 'GSTORE_RESULT err=1';
      final path = match.group(1)!;
      final size = sizes[path];
      if (size == null) return 'GSTORE_RESULT err=1';
      return '$size\nGSTORE_RESULT ok=1';
    }
    return 'GSTORE_RESULT err=1';
  }
}

MiuiThermalBackup _record() => MiuiThermalBackup(
      fileName: '1700000000000__x.bak',
      sourcePath: _targetConf,
      backupPath:
          '$_bkDir/1700000000000__%system%etc%thermal_generic.conf.bak',
      sizeBytes: 512,
      createdAtMs: 1700000000000,
    );

MiuiThermalService _service(_FakeRunner runner) => MiuiThermalService(
      runner: runner.run,
      backupDir: _bkDir,
      clock: () => 1700000000000,
    );

void main() {
  group('RootDetector（fail-closed）', () {
    test('uid=0 → rooted，display 显式「可选」', () async {
      final detector = RootDetector(runner: _FakeRunner(rootUid: '0').run);
      final status = await detector.detect();
      expect(status.rooted, isTrue);
      expect(status.reachable, isTrue);
      expect(status.display, contains('Root 可用'));
    });

    test('uid=2000（非 0）→ 无 Root', () async {
      final detector = RootDetector(runner: _FakeRunner(rootUid: '2000').run);
      final status = await detector.detect();
      expect(status.rooted, isFalse);
      expect(status.display, contains('Shizuku'));
    });

    test('探测命令失败（err）→ 无 Root 但可达', () async {
      final detector = RootDetector(runner: _FakeRunner().run);
      final status = await detector.detect();
      expect(status.rooted, isFalse);
      expect(status.reachable, isTrue);
    });

    test('runner 返回 null → reachable=false，无 Root', () async {
      final detector =
          RootDetector(runner: _FakeRunner(unreachable: true).run);
      final status = await detector.detect();
      expect(status.reachable, isFalse);
      expect(status.rooted, isFalse);
    });

    test('会话缓存：二次探测不重复执行；refresh 强制重探', () async {
      final runner = _FakeRunner(rootUid: '0');
      final detector = RootDetector(runner: runner.run);
      await detector.detect();
      expect(runner.commands, hasLength(1));
      await detector.detect();
      expect(runner.commands, hasLength(1)); // 命中缓存
      await detector.detect(refresh: true);
      expect(runner.commands, hasLength(2)); // refresh 重探
      expect(detector.cached, isNotNull);
    });
  });

  group('RootCapabilityGate（纯门）', () {
    test('Shizuku 主路径恒可用；root-only 仅有 Root 时可用', () {
      const withRoot = RootCapabilityGate(
        RootStatus(rooted: true, reachable: true, uid: '0'),
      );
      const noRoot = RootCapabilityGate(
        RootStatus(rooted: false, reachable: true),
      );
      expect(withRoot.shizukuPrimaryAvailable, isTrue);
      expect(noRoot.shizukuPrimaryAvailable, isTrue);
      expect(
        withRoot.isAvailable(RootOnlyCapability.miuiThermalDirectWrite),
        isTrue,
      );
      expect(
        noRoot.isAvailable(RootOnlyCapability.miuiThermalDirectWrite),
        isFalse,
      );
      expect(
        noRoot.unavailableReason(RootOnlyCapability.miuiThermalDirectWrite),
        isNotNull,
      );
      expect(
        withRoot.unavailableReason(RootOnlyCapability.miuiThermalDirectWrite),
        isNull,
      );
    });

    test('未知能力 id 永远不可用（fail-closed）', () {
      const withRoot = RootCapabilityGate(
        RootStatus(rooted: true, reachable: true, uid: '0'),
      );
      expect(withRoot.isAvailable('some.random.capability'), isFalse);
    });
  });

  group('MIUI 温控 root-only 动作门禁', () {
    test('无 Root → 直写条目 disabled + 显式原因；Shizuku 条目恒可用', () async {
      final runner = _FakeRunner(); // rootUid null = 无 Root
      final caps = await _service(runner).actionCapabilities();

      final direct = caps.firstWhere(
        (c) => c.id == MiuiThermalAction.directWriteAsRoot,
      );
      expect(direct.rootOnly, isTrue);
      expect(direct.available, isFalse);
      expect(direct.reason, isNotNull);
      expect(direct.label, contains('需 Root'));

      final backup = caps.firstWhere((c) => c.id == MiuiThermalAction.backup);
      final restore = caps.firstWhere((c) => c.id == MiuiThermalAction.restore);
      expect(backup.available, isTrue);
      expect(backup.rootOnly, isFalse);
      expect(backup.label, contains('Shizuku'));
      expect(restore.available, isTrue);
      expect(restore.label, contains('Shizuku'));
    });

    test('无 Root → directWriteAsRoot 返回 root_required 且零 cp 命令', () async {
      final runner = _FakeRunner(
        sizes: <String, int>{_record().backupPath: 512},
      );
      final result = await _service(runner)
          .directWriteAsRoot(_record(), confirmed: true);

      expect(result.ok, isFalse);
      expect(result.error, MiuiThermalError.rootRequired);
      expect(runner.commands.where((c) => c.contains('cp -f')), isEmpty);
    });

    test('有 Root → 直写条目 available；directWriteAsRoot 经 su 成功 + 回读', () async {
      final backupPath = _record().backupPath;
      final runner = _FakeRunner(
        rootUid: '0',
        sizes: <String, int>{backupPath: 512},
      );
      final service = _service(runner);

      final caps = await service.actionCapabilities();
      final direct = caps.firstWhere(
        (c) => c.id == MiuiThermalAction.directWriteAsRoot,
      );
      expect(direct.available, isTrue);
      expect(direct.reason, isNull);

      final result = await service.directWriteAsRoot(_record(), confirmed: true);
      expect(result.ok, isTrue);
      final cpCmd = runner.commands.firstWhere((c) => c.contains('cp -f'));
      expect(cpCmd, contains('su -c'));
      expect(cpCmd, contains('cp -f $backupPath $_targetConf'));
      expect(runner.sizes[_targetConf], 512); // 回读一致
    });

    test('有 Root 但缺二次确认 → confirm_required（门禁顺序：Root 先过）', () async {
      final runner = _FakeRunner(
        rootUid: '0',
        sizes: <String, int>{_record().backupPath: 512},
      );
      final result = await _service(runner).directWriteAsRoot(_record());
      expect(result.ok, isFalse);
      expect(result.error, MiuiThermalError.confirmRequired);
      expect(runner.commands.where((c) => c.contains('cp -f')), isEmpty);
    });

    test('默认 Shizuku 恢复路径不变：不经 su', () async {
      final backupPath = _record().backupPath;
      final runner = _FakeRunner(sizes: <String, int>{backupPath: 512});
      final result = await _service(runner).restore(_record(), confirmed: true);
      expect(result.ok, isTrue);
      final cpCmd = runner.commands.firstWhere((c) => c.contains('cp -f'));
      expect(cpCmd.contains('su -c'), isFalse);
    });
  });
}
