import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/channel/ChannelIntegration.dart';
import 'package:gstore/core/channel/ChannelManager.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/module/app_modules.dart';
import 'package:gstore/core/module/module.dart';
import 'package:gstore/core/module/module_manager.dart';
import 'package:gstore/http/github/dio_client.dart';
import 'package:gstore/http/github/github_client.dart';

/// channel 按类型绑定注册表 + 幂等化测试（todo 16）
///
/// 验证：
/// - ChannelModule.onRegister 按类型绑定 → get<ChannelManager>() 返回实例；
///   onUnregister 对称解绑 → null
/// - ChannelIntegration.initialize 幂等：重复调用渠道只注册一次、不重复绑定
///
/// 本地数据库渠道（`LocalDbChannel`）已在纯 Rust 清理中删除：catalog 归 Rust
/// core（`CatalogFacade`），`initialize` 不再注册 `ChannelType.localDb` 实例。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await ModuleManager.instance.clear();
    ModuleManager.instance.injectContext(null);
    await ChannelManager.instance.disposeAll();
    ChannelIntegration.resetForTest();
    // ChannelIntegration.initialize 依赖 ModuleManager 取 GithubRestClient。
    ModuleManager.instance
        .bind<GithubRestClient>(GithubRestClient(DioClient().get()));
  });

  group('ChannelModule 按类型绑定', () {
    test('onRegister 绑定 → get<ChannelManager>() 返回实例；onUnregister 解绑 → null',
        () async {
      final manager = ModuleManager.instance;
      final module = ChannelModule();

      await module.onRegister(ModuleContext(
        config: null,
        bindService: (type, impl) => manager.bindByType(type, impl),
        unbindService: (type) => manager.unbindByType(type),
      ));

      expect(manager.get<ChannelManager>(), same(ChannelManager.instance),
          reason: '按类型绑定后注册表可取到 ChannelManager 实例');

      await module.onUnregister(ModuleContext(
        config: null,
        unbindService: (type) => manager.unbindByType(type),
      ));

      expect(manager.get<ChannelManager>(), isNull,
          reason: '模块下线后注册表解绑，消费方软降级');
    });
  });

  group('ChannelIntegration.initialize 幂等', () {
    test('重复调用：渠道只注册一次、不重复绑定、不抛', () async {
      // 首次初始化（真实渠道注册，ChannelManager 单例复用）
      await ChannelIntegration.initialize();

      final manager = ChannelManager.instance;
      expect(manager.getChannel(ChannelType.github), isNotNull);
      expect(manager.getChannel(ChannelType.vivo), isNotNull);
      expect(manager.getChannel(ChannelType.fdroid), isNotNull);
      // 本地数据库渠道已下线：不注册 Dart 实例，catalog 读取走 CatalogFacade。
      expect(manager.getChannel(ChannelType.localDb), isNull);
      expect(ChannelIntegration.instance, same(manager));
      final githubFirst = manager.getChannel(ChannelType.github);

      // 重复调用（re-enable 场景）：幂等直接返回，渠道不重复注册/不重建实例
      await ChannelIntegration.initialize();
      expect(manager.getChannel(ChannelType.github), same(githubFirst),
          reason: '幂等：重复调用 initialize 不重建渠道实例');
      expect(manager.getChannel(ChannelType.vivo), isNotNull);
      expect(manager.getChannel(ChannelType.fdroid), isNotNull);
      expect(ChannelIntegration.instance, same(manager));
    });
  });
}
