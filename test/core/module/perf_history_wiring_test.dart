// P2a：PerfMonitorModule 在运行期把外部配置变更（备份恢复 / Agent / configManager）
// 驱动的 `perf.history.enabled` 同步到电池历史采样器。
//
// 断言：
//  * 注册时按现值同步：默认 OFF → 收到一次 `false`；
//  * 运行期外部写 true → 收到 `true`（start）；
//  * 运行期外部写 false → 收到 `false`（stop）；
//  * onUnregister 不抛出且取消订阅（下线后再写不再回调）。
//
// 全部密闭：ConfigStore 内存后端；采样器 start/stop 经 historySyncOverride 注入，
// 不触碰真实 BatteryHistoryRecorder / Rust / Shizuku / 定时器。

import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/core/config/config_registry.dart';
import 'package:gstore/core/config/config_service.dart';
import 'package:gstore/core/config/config_store.dart';
import 'package:gstore/core/config/config_storage.dart';
import 'package:gstore/core/module/app_modules.dart';
import 'package:gstore/core/module/module_base.dart';

Future<void> _waitUntil(
  bool Function() condition, {
  int timeoutMs = 2000,
}) async {
  final deadline = DateTime.now().add(Duration(milliseconds: timeoutMs));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PerfMonitorModule module;
  late List<bool> captured;

  ModuleContext context() => ModuleContext(config: ConfigService.instance);

  setUp(() async {
    PerfMonitorModule.coordinatorFactoryOverride = null;
    PerfMonitorModule.historySyncOverride = null;
    ConfigStore.instance.resetForTest();
    await ConfigStore.instance.initialize(storages: <ConfigStorage>[
      MemoryConfigStorage(),
      MemoryConfigStorage(),
    ]);
    ConfigRegistry.registerAll(ConfigService.instance);
    await ConfigService.instance.ensureReady();

    captured = <bool>[];
    PerfMonitorModule.historySyncOverride = (bool enabled) async {
      captured.add(enabled);
    };
    module = PerfMonitorModule();
  });

  tearDown(() {
    PerfMonitorModule.coordinatorFactoryOverride = null;
    PerfMonitorModule.historySyncOverride = null;
  });

  test('默认 OFF：注册时同步为 false；外部写 true/false 驱动 start/stop', () async {
    final ctx = context();

    await module.onInit(ctx);
    await module.onRegister(ctx);

    expect(captured, <bool>[false], reason: '默认 OFF 应在注册时同步一次 false');

    await ConfigStore.instance.write(ConfigKeys.perfHistoryEnabled, true);
    await _waitUntil(() => captured.contains(true));
    expect(captured, contains(true), reason: '外部开启必须驱动采样器 start');

    await ConfigStore.instance.write(ConfigKeys.perfHistoryEnabled, false);
    await _waitUntil(() => captured.isNotEmpty && captured.last == false);
    expect(captured.last, isFalse, reason: '外部关闭必须驱动采样器 stop');

    await module.onUnregister(ctx);
    expect(captured.last, isFalse);

    // 下线后订阅已取消：再写 true 不应再回调。
    final before = captured.length;
    await ConfigStore.instance.write(ConfigKeys.perfHistoryEnabled, true);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(captured.length, before, reason: '下线后必须取消开关订阅');
  });
}
