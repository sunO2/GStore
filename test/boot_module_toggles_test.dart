import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/config/config_registry.dart';
import 'package:gstore/core/config/config_service.dart';
import 'package:gstore/core/config/config_store.dart';
import 'package:gstore/core/config/config_storage.dart';
import 'package:gstore/core/module/module.dart';
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

/// 测试接口（模拟业务模块 onRegister 绑定服务）
abstract class IBootTestService {
  String get name;
}

class BootTestService implements IBootTestService {
  @override
  String get name => 'boot-test';
}

/// 测试模块：onRegister 绑定服务，onInit 计数
class BootTestModule extends AppModule {
  BootTestModule(this.name);

  final String name;
  int initCalls = 0;

  @override
  String get moduleName => name;

  @override
  int get priority => 10;

  @override
  Future<void> onInit(ModuleContext context) async {
    initCalls++;
  }

  @override
  Future<void> onRegister(ModuleContext context) async {
    context.bindService?.call(IBootTestService, BootTestService());
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await initForTest();
    final manager = ModuleManager.instance;
    await manager.clear();
    // 注入与 main.dart 一致的 ModuleContext（bindService 联动 manager）
    manager.injectContext(ModuleContext(
      config: ConfigService.instance,
      bindService: (type, impl) => manager.bindByType(type, impl),
      unbindService: (type) => manager.unbindByType(type),
      manager: manager,
    ));
  });

  group('preApplyToggles 启动预置（registerModule 完成后、initializeAll 前）', () {
    test('module.webdav.enabled=false → 预置后 initializeAll 跳过 webdav'
        '（isInitialized false + 服务未绑定）', () async {
      final setResult = await ConfigService.instance
          .set(ModuleToggleConfig.keyOf('webdav'), false);
      expect(setResult.success, true, reason: 'module.webdav.enabled 应已注册');

      final manager = ModuleManager.instance;
      manager.registerKnownModules(() => [BootTestModule('webdav')]);
      await manager.registerModule(BootTestModule('webdav'));

      await ModuleToggleConfig.preApplyToggles(manager);
      await manager.initializeAll();

      expect(manager.isInitialized('webdav'), false,
          reason: 'disabled 模块启动应跳过初始化');
      expect(manager.get<IBootTestService>(), null,
          reason: 'disabled 模块的服务不应绑定');
    });

    test('配置缺失默认启用：预置不误关，模块正常初始化', () async {
      final manager = ModuleManager.instance;
      manager.registerKnownModules(() => [BootTestModule('webdav')]);
      await manager.registerModule(BootTestModule('webdav'));

      await ModuleToggleConfig.preApplyToggles(manager);
      await manager.initializeAll();

      expect(manager.isInitialized('webdav'), true);
      expect(manager.get<IBootTestService>(), isNotNull);
      expect(manager.isModuleEnabled('webdav'), true);
    });

    test('update/badge 不在可开关清单：即使配置 disabled 也不被预置禁用', () async {
      final setUpdate = await ConfigService.instance
          .set(ModuleToggleConfig.keyOf('update'), false);
      final setBadge = await ConfigService.instance
          .set(ModuleToggleConfig.keyOf('badge'), false);
      expect(setUpdate.success, true);
      expect(setBadge.success, true);

      final manager = ModuleManager.instance;
      manager.registerKnownModules(
          () => [BootTestModule('update'), BootTestModule('badge')]);
      await manager.registerModule(BootTestModule('update'));
      await manager.registerModule(BootTestModule('badge'));

      await ModuleToggleConfig.preApplyToggles(manager);
      await manager.initializeAll();

      expect(manager.isInitialized('update'), true,
          reason: 'update 恒启用，不得被预置禁用');
      expect(manager.isInitialized('badge'), true,
          reason: 'badge 恒启用，不得被预置禁用');
      expect(manager.isModuleEnabled('update'), true);
      expect(manager.isModuleEnabled('badge'), true);
    });
  });
}
