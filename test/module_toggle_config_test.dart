import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/config/config_registry.dart';
import 'package:gstore/core/config/config_service.dart';
import 'package:gstore/core/config/config_store.dart';
import 'package:gstore/core/config/config_storage.dart';
import 'package:gstore/core/module/module.dart';
import 'package:gstore/core/module/module_manager.dart';
import 'package:gstore/core/module/module_toggle_config.dart';

/// 测试用统一初始化：全部使用内存存储（避免插件依赖）
Future<void> initForTest() async {
  ConfigStore.instance.resetForTest();
  await ConfigStore.instance.initialize(storages: [
    MemoryConfigStorage(),
    MemoryConfigStorage(),
  ]);
  ConfigRegistry.registerAll(ConfigService.instance);
}

/// 测试模块（验证 manager 上下线联动）
class ToggleTestModule extends AppModule {
  ToggleTestModule(this.name, {this.dependencies = const []});

  final String name;

  @override
  final List<String> dependencies;

  int registerCalls = 0;
  int unregisterCalls = 0;

  @override
  String get moduleName => name;

  @override
  int get priority => 10;

  @override
  Future<void> onRegister(ModuleContext context) async {
    registerCalls++;
  }

  @override
  Future<void> onUnregister(ModuleContext context) async {
    unregisterCalls++;
  }
}

/// 写入失败的存储（模拟 ConfigService.set 持久化失败）
class _FailingMemoryStorage extends MemoryConfigStorage {
  @override
  Future<bool> setValue(String key, Object? value) async => false;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await initForTest();
    await ModuleManager.instance.clear();
  });

  group('ModuleToggleConfig key 注册', () {
    test('module.<name>.enabled 11 key 已注册（set 不返 failure）', () async {
      const modules = [
        'channel',
        'download',
        'backup',
        'webdav',
        'fdroid',
        'theme',
        'install',
        'aggregate',
        'agent_tools',
        'update',
        'badge',
      ];
      final service = ConfigService.instance;
      for (final name in modules) {
        final key = ModuleToggleConfig.keyOf(name);
        expect(service.has(key), true, reason: '$key 应已注册');
        final result = await service.set(key, true);
        expect(result.success, true, reason: '$key 写入应成功');
      }
    });
  });

  group('ModuleToggleConfig isModuleEnabled', () {
    test('未设置（默认）返回 true', () async {
      final config = ModuleToggleConfig.instance;
      // 已注册但从未写入 → 默认启用
      expect(await config.isModuleEnabled('channel'), true);
      expect(await config.isModuleEnabled('webdav'), true);
    });

    test('完全未注册的模块名也默认 true（fail-safe）', () async {
      final config = ModuleToggleConfig.instance;
      expect(await config.isModuleEnabled('ghost_module'), true);
    });

    test('显式写入 false 后读取为 false', () async {
      final config = ModuleToggleConfig.instance;
      await config.setEnabled('channel', false);
      expect(await config.isModuleEnabled('channel'), false);
    });
  });

  group('ModuleToggleConfig setEnabled roundtrip', () {
    test('set→get roundtrip（true/false 均可持久化）', () async {
      final config = ModuleToggleConfig.instance;
      final manager = ModuleManager.instance;
      // re-enable 需要从 known-modules 查实例，先注册模块源
      manager.registerKnownModules(() => [ToggleTestModule('channel')]);

      expect(await config.setEnabled('channel', false), true);
      expect(await config.isModuleEnabled('channel'), false);

      expect(await config.setEnabled('channel', true), true);
      expect(await config.isModuleEnabled('channel'), true);
    });

    test('未注册 key 写入失败返回 false', () async {
      final config = ModuleToggleConfig.instance;
      expect(await config.setEnabled('ghost_module', false), false);
    });
  });

  group('ModuleToggleConfig setEnabled 联动 manager', () {
    test('禁用触发 unregister + 重新启用触发 activate', () async {
      final config = ModuleToggleConfig.instance;
      final manager = ModuleManager.instance;
      final module = ToggleTestModule('channel');

      manager.registerKnownModules(() => [module]);
      await manager.activate(module);
      expect(manager.isInitialized('channel'), true);
      expect(module.registerCalls, 1);

      // 禁用：已初始化 → unregisterModule → 下线
      expect(await config.setEnabled('channel', false), true);
      expect(manager.hasModule('channel'), false);
      expect(manager.isModuleEnabled('channel'), false);
      expect(module.unregisterCalls, 1);

      // 重新启用：从 known-modules 查实例 → activate
      expect(await config.setEnabled('channel', true), true);
      expect(manager.hasModule('channel'), true);
      expect(manager.isModuleEnabled('channel'), true);
      expect(manager.isInitialized('channel'), true);
      expect(module.registerCalls, 2);
    });

    test('依赖者拒绝时配置值保持原状（不落盘）', () async {
      final config = ModuleToggleConfig.instance;
      final manager = ModuleManager.instance;
      // channel 被 app 依赖且均已初始化 → 关闭 channel 被拒
      await manager.registerModule(ToggleTestModule('channel'));
      await manager.registerModule(ToggleTestModule('app', dependencies: ['channel']));
      await manager.initializeAll();

      // 基线：确立配置为 true
      expect(await config.setEnabled('channel', true), true);
      expect(await config.isModuleEnabled('channel'), true);

      final ok = await config.setEnabled('channel', false);
      expect(ok, false, reason: '依赖者拒绝必须返回 false');
      expect(await config.isModuleEnabled('channel'), true,
          reason: '依赖者拒绝时配置不得落盘为 false');
      expect(manager.isModuleEnabled('channel'), true, reason: '模块保持启用');
    });
  });

  group('ModuleToggleConfig setEnabled 持久化失败回滚', () {
    test('ConfigService.set 失败：返回 false 且回滚运行时切换', () async {
      // 独立初始化：首个存储写入失败（注册表仍由 setUp 注册）
      ConfigStore.instance.resetForTest();
      await ConfigStore.instance.initialize(storages: [
        _FailingMemoryStorage(),
        MemoryConfigStorage(),
      ]);
      await ModuleManager.instance.clear();
      final config = ModuleToggleConfig.instance;
      final manager = ModuleManager.instance;
      final module = ToggleTestModule('channel');
      manager.registerKnownModules(() => [module]);

      final ok = await config.setEnabled('channel', false);
      expect(ok, false, reason: '持久化失败必须返回 false');
      expect(module.registerCalls, 1,
          reason: '已做的运行时切换被回滚（重新激活）');
      expect(manager.isModuleEnabled('channel'), true, reason: '模块保持启用');
      expect(await config.isModuleEnabled('channel'), true,
          reason: '配置未落盘');
    });
  });

  group('ModuleToggleConfig watch', () {
    test('watch 收到 bool 值变化事件', () async {
      final config = ModuleToggleConfig.instance;
      final manager = ModuleManager.instance;
      // 新顺序下 re-enable 需从 known-modules 查实例（否则 manager 拒绝、不落盘）
      manager.registerKnownModules(() => [ToggleTestModule('channel')]);
      final seen = <bool>[];
      final sub = config.watch('channel').listen(seen.add);

      await config.setEnabled('channel', false);
      await config.setEnabled('channel', true);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(seen, [false, true]);
      await sub.cancel();
    });
  });
}
