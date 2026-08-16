import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/config/config_store.dart';
import 'package:gstore/core/config/config_storage.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/module/app_modules.dart';
import 'package:gstore/page/agent/logic.dart';
import 'package:gstore/page/agent/view.dart';
import 'package:gstore/page/home/logic.dart';
import 'package:gstore/http/github/dio_client.dart';
import 'package:gstore/http/github/github_client.dart';

/// 测试用统一初始化：全部使用内存存储（避免插件依赖）
Future<void> initForTest() async {
  ConfigStore.instance.resetForTest();
  await ConfigStore.instance.initialize(storages: [
    MemoryConfigStorage(),
    MemoryConfigStorage(),
  ]);
  ConfigRegistry.registerAll(ConfigService.instance);
}

/// 无依赖桩模块（补齐 agent_tools 的 config/channel 依赖声明）
class _StubModule extends AppModule {
  _StubModule(this.moduleName);

  @override
  final String moduleName;
}

/// Agent 服务纳入模块管理 + 消费方注册表化降级测试
///
/// 验证：
/// ① AgentToolsModule 上线（onInit + onRegister）后 get<AgentService>() 返回实例
/// ② agent_tools 禁用（setModuleEnabled(false)）→ onUnregister 解绑 → get<AgentService>() null
/// ③ AgentLogic 服务 null 时初始化/发送不抛且置「Agent 模块未启用」提示
/// ④ Agent 页对话提交在服务 null 时弹提示不发送（widget 测试）
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await ModuleManager.instance.clear();
    ModuleManager.instance.injectContext(null);
    Get.reset();
    await initForTest();
  });

  group('AgentToolsModule 管理 AgentService（注册表化）', () {
    test('① 模块注册+初始化后 get<AgentService>() 返回实例（bind 生效）', () async {
      final manager = ModuleManager.instance;
      manager.injectContext(ModuleContext(
        config: ConfigService.instance,
        bindService: (type, impl) => manager.bindByType(type, impl),
        unbindService: (type) => manager.unbindByType(type),
        manager: manager,
      ));

      final module = AgentToolsModule();
      await module.onInit(ModuleContext(config: ConfigService.instance));
      await module.onRegister(ModuleContext(
        config: ConfigService.instance,
        bindService: (type, impl) => manager.bindByType(type, impl),
        manager: manager,
      ));

      expect(Get.isRegistered<AgentService>(), isTrue,
          reason: 'onInit 应 Get.put AgentService');
      expect(manager.get<AgentService>(), isNotNull,
          reason: 'onRegister 应按类型绑定 AgentService');
    });

    test('② agent_tools 禁用（setModuleEnabled(false)）→ unbind → get<AgentService>() null',
        () async {
      final manager = ModuleManager.instance;
      manager.injectContext(ModuleContext(
        config: ConfigService.instance,
        bindService: (type, impl) => manager.bindByType(type, impl),
        unbindService: (type) => manager.unbindByType(type),
        manager: manager,
      ));

      // 补齐依赖声明（config/channel 用无依赖桩模块）
      await manager.registerModule(_StubModule('config'));
      await manager.registerModule(_StubModule('channel'));
      await manager.registerModule(AgentToolsModule());
      await manager.initializeModule('agent_tools');
      expect(manager.get<AgentService>(), isNotNull,
          reason: '上线后服务应已绑定');

      final ok = await manager.setModuleEnabled('agent_tools', false);
      expect(ok, isTrue);
      expect(manager.hasModule('agent_tools'), isFalse);
      expect(manager.get<AgentService>(), isNull,
          reason: '下线后服务应已解绑（消费方降级）');
    });
  });

  group('AgentLogic 服务 null 降级', () {
    test('③ 服务 null 时初始化不抛且置未启用提示', () async {
      final logic = AgentLogic();
      await logic.ensureInitialized();

      expect(logic.agentUnavailable, isTrue);
      expect(logic.state.isInitialized.value, isFalse);
      expect(logic.state.errorMessage.value, 'Agent 模块未启用');
    });

    test('③b 服务 null 时 sendText 不抛且置未启用提示', () async {
      final logic = AgentLogic();
      await logic.sendText('hello');

      expect(logic.state.errorMessage.value, 'Agent 模块未启用');
    });
  });

  group('Agent 页对话提交降级（widget）', () {
    testWidgets('④ 服务 null 时提交弹提示不发送', (tester) async {
      // HomeLogic 的 GithubRequestMix 构造时 Get.find<GithubRestClient>()
      Get.put(GithubRestClient(DioClient().get()));
      Get.put(HomeLogic());
      await tester.pumpWidget(MaterialApp(
        scaffoldMessengerKey: AppDialogs.scaffoldMessengerKey,
        home: const AgentPage(),
      ));
      await tester.pump();

      // 未启用提示可见（页面不崩）
      expect(find.text('Agent 模块未启用'), findsWidgets);

      // 输入并点击发送 → 弹提示（snackbar），不发送
      await tester.enterText(find.byType(TextField), 'hello');
      await tester.tap(find.byIcon(Icons.send));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Agent 模块未启用'), findsWidgets,
          reason: '提交应弹「Agent 模块未启用」提示');
    });
  });
}