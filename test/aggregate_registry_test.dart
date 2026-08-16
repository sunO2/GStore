import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:gstore/core/aggregate/AppAggregatorManager.dart';
import 'package:gstore/core/module/app_modules.dart';
import 'package:gstore/core/module/interfaces/service_interfaces.dart';
import 'package:gstore/core/module/module.dart';
import 'package:gstore/core/module/module_manager.dart';
import 'package:gstore/core/service/backup_service.dart';
import 'package:gstore/core/service/install_manager.dart';
import 'package:gstore/http/github/dio_client.dart';
import 'package:gstore/http/github/github_client.dart';
import 'package:gstore/page/home/tab/applist/logic.dart';

/// aggregate/install/backup 消费方注册表化测试（todo 17）
///
/// 验证：
/// - AggregateModule/InstallModule/BackupModule onRegister 绑定服务接口 →
///   get<IAggregateService>()/get<IInstallService>()/get<IBackupService>() 返回实例；
///   onUnregister 对称解绑 → null
/// - ApplistLogic 迁移点 null 降级：aggregate 模块下线时 onReady 不抛
///   （不订阅、不加载，页面空态）
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await ModuleManager.instance.clear();
    ModuleManager.instance.injectContext(null);
    // ApplistLogic 混入 GithubRequestMix，构造时 Get.find<GithubRestClient>()
    Get.put(GithubRestClient(DioClient().get()));
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

  group('ApplistLogic 迁移点 null 降级', () {
    test('aggregate 模块下线（get<IAggregateService>() == null）→ onReady 不抛', () async {
      final logic = ApplistLogic();
      logic.onReady();

      // 降级路径：不订阅、不加载，页面空态（不抛 Get.find 异常）
      expect(logic.state.apps, isEmpty);
    });
  });
}