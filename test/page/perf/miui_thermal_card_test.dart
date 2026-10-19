import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/navigation/nav_key.dart';
import 'package:gstore/core/perf/miui_thermal.dart';
import 'package:gstore/page/perf/hardware_page.dart';

const String _systemConf = '/system/etc/thermal_generic.conf';

/// 假服务：受控返回检测 / 诊断 / 备份，记录 backup / restore 调用；
/// **不触碰 Shizuku / 真机**。
class _FakeService extends MiuiThermalService {
  _FakeService({
    required this.detection,
    this.configs = const <ThermalConfigEntry>[],
    this.backups = const <MiuiThermalBackup>[],
  }) : super(runner: (command) async => null);

  MiuiDetection detection;
  List<ThermalConfigEntry> configs;
  List<MiuiThermalBackup> backups;
  int backupCalls = 0;
  int restoreCalls = 0;

  @override
  Future<MiuiDetection> detect() async => detection;

  @override
  Future<ThermalDiagnostic> diagnose() async =>
      ThermalDiagnostic(configs: configs);

  @override
  Future<List<MiuiThermalBackup>> listBackups() async => backups;

  @override
  Future<MiuiThermalActionResult> backup(String path) async {
    backupCalls++;
    return MiuiThermalActionResult.success('ok');
  }

  @override
  Future<MiuiThermalActionResult> restore(
    MiuiThermalBackup backup, {
    bool confirmed = false,
  }) async {
    restoreCalls++;
    return MiuiThermalActionResult.success('ok');
  }
}

MiuiDetection _miui() => const MiuiDetection(
      isMiui: true,
      reachable: true,
      versionName: 'V816.0.1.0',
      versionCode: '14',
    );

MiuiThermalBackup _backup() => const MiuiThermalBackup(
      fileName: '1700000000000__x.bak',
      sourcePath: _systemConf,
      backupPath:
          '/data/local/tmp/gstore_miui_thermal_backup/1700000000000__x.bak',
      sizeBytes: 512,
      createdAtMs: 1700000000000,
    );

Widget _harness(MiuiThermalService service) => ProviderScope(
      overrides: [
        miuiThermalServiceProvider.overrideWithValue(service),
      ],
      child: MaterialApp(
        navigatorKey: appNavigatorKey,
        scaffoldMessengerKey: AppDialogs.scaffoldMessengerKey,
        home: const Scaffold(
          body: SingleChildScrollView(child: MiuiThermalCard()),
        ),
      ),
    );

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

/// 铺满大视口（避免底部弹层确认按钮落在 800x600 之外而点不中）。
void _useTallViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 6000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('MIUI：渲染配置列表 / 备份列表 / 备份按钮触发', (tester) async {
    _useTallViewport(tester);
    final service = _FakeService(
      detection: _miui(),
      configs: const <ThermalConfigEntry>[
        ThermalConfigEntry(path: _systemConf, sizeBytes: 512),
      ],
      backups: <MiuiThermalBackup>[_backup()],
    );
    await tester.pumpWidget(_harness(service));
    await _settle(tester);

    expect(find.byKey(const Key('miui_thermal_card')), findsOneWidget);
    expect(find.byKey(const Key('miui_thermal_refresh')), findsOneWidget);
    expect(find.text('MIUI 温控'), findsOneWidget);
    expect(find.textContaining('MIUI V816.0.1.0'), findsOneWidget);

    // 配置列表 + 大小 + 备份按钮。
    expect(find.byKey(const Key('miui_thermal_configs')), findsOneWidget);
    expect(find.text(_systemConf), findsOneWidget);
    expect(find.byKey(const Key('miui_thermal_backup_0')), findsOneWidget);

    // 备份列表 + 恢复按钮。
    expect(find.byKey(const Key('miui_thermal_backups')), findsOneWidget);
    expect(find.byKey(const Key('miui_thermal_restore_0')), findsOneWidget);

    // 点击备份 → 调用服务。
    await tester.tap(find.byKey(const Key('miui_thermal_backup_0')));
    await _settle(tester);
    expect(service.backupCalls, 1);

    expect(tester.takeException(), isNull);
  });

  testWidgets('恢复：危险确认弹层 → 确认后调用 restore(confirmed: true)',
      (tester) async {
    _useTallViewport(tester);
    final service = _FakeService(
      detection: _miui(),
      configs: const <ThermalConfigEntry>[
        ThermalConfigEntry(path: _systemConf, sizeBytes: 512),
      ],
      backups: <MiuiThermalBackup>[_backup()],
    );
    await tester.pumpWidget(_harness(service));
    await _settle(tester);

    await tester.tap(find.byKey(const Key('miui_thermal_restore_0')));
    await _settle(tester);
    // 完成底部弹层滑入动画（此时无 loading 无限动画，可安全 settle）。
    await tester.pumpAndSettle();

    // 危险确认弹层出现。
    expect(find.text('恢复温控配置？'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '恢复'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, '恢复'));
    await tester.pumpAndSettle();
    expect(service.restoreCalls, 1);

    expect(tester.takeException(), isNull);
  });

  testWidgets('非 MIUI：显示「非 MIUI（本卡不可用）」，无配置 / 备份操作',
      (tester) async {
    _useTallViewport(tester);
    final service = _FakeService(
      detection: const MiuiDetection(isMiui: false, reachable: true),
      configs: const <ThermalConfigEntry>[
        ThermalConfigEntry(path: _systemConf, sizeBytes: 512),
      ],
    );
    await tester.pumpWidget(_harness(service));
    await _settle(tester);

    expect(find.text('非 MIUI（本卡不可用）'), findsOneWidget);
    expect(find.byKey(const Key('miui_thermal_configs')), findsNothing);
    expect(find.byKey(const Key('miui_thermal_backups')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Shizuku 不可达：禁用 + 原因，无配置列表', (tester) async {
    _useTallViewport(tester);
    final service = _FakeService(
      detection: const MiuiDetection(isMiui: false, reachable: false),
      configs: const <ThermalConfigEntry>[
        ThermalConfigEntry(path: _systemConf, sizeBytes: 512),
      ],
    );
    await tester.pumpWidget(_harness(service));
    await _settle(tester);

    expect(find.textContaining('Shizuku 不可用'), findsOneWidget);
    expect(find.byKey(const Key('miui_thermal_configs')), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
