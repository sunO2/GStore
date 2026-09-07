import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:gstore/core/aggregate/AppAggregatorManager.dart';
import 'package:gstore/core/module/app_modules.dart';
import 'package:gstore/core/module/interfaces/service_interfaces.dart';
import 'package:gstore/core/module/module.dart';
import 'package:gstore/core/service/backup_service.dart';
import 'package:gstore/core/service/install_manager.dart';
import 'package:gstore/page/home/tab/applist/logic.dart';

/// aggregate/install/backup 消费方注册表化测试（todo 17）
///
/// 验证：
/// - AggregateModule/InstallModule/BackupModule onRegister 绑定服务接口 →
///   get<IAggregateService>()/get<IInstallService>()/get<IBackupService>() 返回实例；
///   onUnregister 对称解绑 → null
/// - ApplistNotifier 迁移点 null 降级：aggregate 模块下线时初始化不抛
///   （不订阅、不加载，页面空态）
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await ModuleManager.instance.clear();
    ModuleManager.instance.injectContext(null);
    Get.reset();
    // ApplistNotifier 不再混入 GithubRequestMix（无 Get.find 构造依赖）
  });

  group('模块绑定 → 注册表可取；解绑 → null', () {
    test('AggregateModule：get<IAggregateService>() 返回实例，下线后 null', () async {
      final manager = ModuleManager.instance;
      final module = AggregateModule();

      await module.onRegister(ModuleContext(
        config: null,
        bindService: (type, impl) => manager.bindByType(type, impl),
        unbindService: (type) => manager.unbindByType(type),
      ));

      expect(manager.get<IAggregateService>(),
          same(AppAggregatorManager.instance));

      await module.onUnregister(ModuleContext(
        config: null,
        unbindService: (type) => manager.unbindByType(type),
      ));

      expect(manager.get<IAggregateService>(), isNull);
    });

    test('InstallModule：get<IInstallService>() 返回实例，下线后 null', () async {
      final manager = ModuleManager.instance;
      final module = InstallModule();

      await module.onRegister(ModuleContext(
        config: null,
        bindService: (type, impl) => manager.bindByType(type, impl),
        unbindService: (type) => manager.unbindByType(type),
      ));

      expect(manager.get<IInstallService>(), same(InstallManager.instance));

      await module.onUnregister(ModuleContext(
        config: null,
        unbindService: (type) => manager.unbindByType(type),
      ));

      expect(manager.get<IInstallService>(), isNull);
    });

    test('BackupModule：get<IBackupService>() 返回实例，下线后 null', () async {
      final manager = ModuleManager.instance;
      final module = BackupModule();

      await module.onRegister(ModuleContext(
        config: null,
        bindService: (type, impl) => manager.bindByType(type, impl),
        unbindService: (type) => manager.unbindByType(type),
      ));

      expect(manager.get<IBackupService>(), same(BackupService.instance));

      await module.onUnregister(ModuleContext(
        config: null,
        unbindService: (type) => manager.unbindByType(type),
      ));

      expect(manager.get<IBackupService>(), isNull);
    });
  });

  group('ApplistNotifier 迁移点 null 降级', () {
    test('aggregate 模块下线（get<IAggregateService>() == null）→ 初始化不抛', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final notifier = container.read(applistProvider.notifier);
      // 触发首帧初始化 microtask
      container.read(applistProvider);
      await Future<void>.delayed(const Duration(milliseconds: 10));

      // 降级路径：不订阅、不加载，页面空态（不抛 Get.find 异常）
      expect(container.read(applistProvider).apps, isEmpty);
      expect(notifier.searchController.text, isEmpty); // 控制器正常创建
    });
  });
}