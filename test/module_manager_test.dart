import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/module/module.dart';
import 'package:gstore/core/module/module_event.dart';
import 'package:gstore/core/module/module_manager.dart';
import 'package:gstore/core/module/module_proxy.dart';

/// 测试接口
abstract class ITestService {
  String greet(String name);
  int add(int a, int b);
  String get version;
}

/// 测试服务实现
class TestService implements ITestService {
  final String id;
  TestService(this.id);

  @override
  String greet(String name) => 'hello $name from $id';

  @override
  int add(int a, int b) => a + b;

  @override
  String get version => 'v1-$id';
}

/// 测试模块
class TestModule extends AppModule {
  TestModule({
    String? name,
    this.registerCalls = 0,
    this.unregisterCalls = 0,
  }) : moduleName = name ?? 'test_module';

  @override
  final String moduleName;

  int registerCalls;
  int unregisterCalls;

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

/// 记录事件
class EventRecorder {
  final List<ModuleEvent> events = [];

  void add(ModuleEvent e) => events.add(e);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    // 重置单例内部状态（模块与服务）
    final manager = ModuleManager.instance;
    await manager.clear();
    manager.injectContext(null);
  });

  group('ModuleManager 注册/注销', () {
    test('registerModule 上线后可查询', () async {
      final manager = ModuleManager.instance;
      final module = TestModule(name: 'mod_a');
      await manager.registerModule(module);

      expect(manager.hasModule('mod_a'), true);
      expect(manager.moduleNames, ['mod_a']);
      expect(manager.moduleCount, 1);
      expect(manager.getModule('mod_a'), same(module));
    });

    test('unregisterModule 下线后移除', () async {
      final manager = ModuleManager.instance;
      await manager.registerModule(TestModule(name: 'mod_a'));
      expect(manager.hasModule('mod_a'), true);

      await manager.unregisterModule('mod_a');
      expect(manager.hasModule('mod_a'), false);
      expect(manager.moduleCount, 0);
    });

    test('注销未注册模块不报错', () async {
      final manager = ModuleManager.instance;
      await manager.unregisterModule('not_exists');
      expect(manager.moduleCount, 0);
    });

    test('同名模块重复注册 = 重新上线（需重新初始化）', () async {
      final manager = ModuleManager.instance;
      final m1 = TestModule(name: 'mod_a');
      final m2 = TestModule(name: 'mod_a');

      await manager.registerModule(m1);
      await manager.initializeModule('mod_a');
      expect(m1.registerCalls, 1);

      await manager.registerModule(m2);
      expect(m1.unregisterCalls, 1); // 旧模块被下线
      expect(m2.registerCalls, 0); // 新模块尚未初始化（登记不初始化）
      expect(manager.isInitialized('mod_a'), false);

      await manager.initializeModule('mod_a');
      expect(m2.registerCalls, 1); // 重新初始化后上线
      expect(manager.getModule('mod_a'), same(m2));
    });

    test('生命周期钩子按上线/下线调用（initializeModule 触发）', () async {
      final manager = ModuleManager.instance;
      final module = TestModule(name: 'mod_a');
      await manager.registerModule(module);
      expect(module.registerCalls, 0); // 仅登记不初始化

      await manager.initializeModule('mod_a');
      expect(module.registerCalls, 1);
      expect(manager.isInitialized('mod_a'), true);

      await manager.unregisterModule('mod_a');
      expect(module.unregisterCalls, 1);
      expect(manager.isInitialized('mod_a'), false);
    });
  });

  group('ModuleManager 上下线事件', () {
    test('注册与注销均广播事件', () async {
      final manager = ModuleManager.instance;
      final recorder = EventRecorder();
      final sub = manager.onChange.listen(recorder.add);

      await manager.registerModule(TestModule(name: 'mod_a'));
      await manager.unregisterModule('mod_a');

      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(recorder.events, hasLength(2));
      expect(recorder.events[0].moduleName, 'mod_a');
      expect(recorder.events[0].lifecycle, ModuleLifecycle.registered);
      expect(recorder.events[1].lifecycle, ModuleLifecycle.unregistered);

      await sub.cancel();
    });

    test('事件流关闭后注册不崩溃', () async {
      final manager = ModuleManager.instance;
      final recorder = EventRecorder();
      final sub = manager.onChange.listen(recorder.add);
      await sub.cancel();

      await manager.registerModule(TestModule(name: 'mod_a'));
      expect(manager.hasModule('mod_a'), true);
    });
  });

  group('ModuleManager watchModule 指定模块监听', () {
    test('watchModule 只收到指定模块的上下线事件', () async {
      final manager = ModuleManager.instance;
      final recorder = EventRecorder();
      final sub = manager.watchModule('webdav').listen(recorder.add);

      // webdav 自身上下线 → 应收到
      await manager.registerModule(TestModule(name: 'webdav'));
      await manager.unregisterModule('webdav');
      // 其他模块上下线 → 不应触发 webdav 监听
      await manager.registerModule(TestModule(name: 'other'));
      await manager.unregisterModule('other');

      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(recorder.events, hasLength(2));
      expect(recorder.events[0].moduleName, 'webdav');
      expect(recorder.events[0].lifecycle, ModuleLifecycle.registered);
      expect(recorder.events[1].moduleName, 'webdav');
      expect(recorder.events[1].lifecycle, ModuleLifecycle.unregistered);

      await sub.cancel();
    });

    test('watchModule 对未注册模块监听不报错', () async {
      final manager = ModuleManager.instance;
      final sub = manager.watchModule('ghost').listen((_) {});

      await manager.registerModule(TestModule(name: 'real'));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      await sub.cancel();
      expect(manager.hasModule('real'), true);
    });
  });

  group('ModuleManager setModuleEnabled 运行时上下线', () {
    test('未初始化模块禁用后 initializeAll 跳过且 isInitialized 保持 false', () async {
      final manager = ModuleManager.instance;
      final module = TestModule(name: 'webdav');
      await manager.registerModule(module);

      final ok = await manager.setModuleEnabled('webdav', false);
      expect(ok, true);
      expect(manager.isModuleEnabled('webdav'), false);

      await manager.initializeAll();
      expect(module.registerCalls, 0, reason: '禁用模块不得被初始化');
      expect(manager.isInitialized('webdav'), false);
    });

    test('已初始化模块禁用：unregister + unregistered 事件 + 服务解绑', () async {
      final manager = ModuleManager.instance;
      manager.injectContext(ModuleContext(
        config: null,
        bindService: (t, impl) => manager.bindByType(t, impl),
        unbindService: (t) => manager.unbindByType(t),
      ));
      final recorder = EventRecorder();
      final sub = manager.watchModule('toggle_svc').listen(recorder.add);

      final module = _ToggleServiceModule();
      await manager.registerModule(module);
      await manager.initializeModule('toggle_svc');
      expect(manager.get<ITestService>(), isNotNull);

      final ok = await manager.setModuleEnabled('toggle_svc', false);
      expect(ok, true);
      expect(module.unregisterCalls, 1, reason: '禁用触发 onUnregister');
      expect(manager.hasModule('toggle_svc'), false);
      expect(manager.get<ITestService>(), isNull, reason: '服务已解绑');
      expect(manager.isInitialized('toggle_svc'), false);

      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(recorder.events.last.lifecycle, ModuleLifecycle.unregistered);

      await sub.cancel();
    });

    test('启用重新 activate：registered 事件 + 服务重绑', () async {
      final manager = ModuleManager.instance;
      manager.injectContext(ModuleContext(
        config: null,
        bindService: (t, impl) => manager.bindByType(t, impl),
        unbindService: (t) => manager.unbindByType(t),
      ));
      final recorder = EventRecorder();
      final sub = manager.watchModule('toggle_svc').listen(recorder.add);

      final module = _ToggleServiceModule();
      manager.registerKnownModules(() => [module]);

      await manager.setModuleEnabled('toggle_svc', false);
      final ok = await manager.setModuleEnabled('toggle_svc', true);
      expect(ok, true);
      expect(manager.hasModule('toggle_svc'), true);
      expect(manager.isInitialized('toggle_svc'), true);
      expect(manager.get<ITestService>(), isNotNull, reason: '服务已重绑');
      expect(manager.getModule('toggle_svc'), same(module));

      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(recorder.events.last.lifecycle, ModuleLifecycle.registered);

      await sub.cancel();
    });

    test('有活跃依赖者时 disable 返回 false 且模块保持', () async {
      final manager = ModuleManager.instance;
      await manager.registerModule(_OrderModule('base', const [], []));
      await manager.registerModule(_OrderModule('app', ['base'], []));
      await manager.initializeAll();

      final ok = await manager.setModuleEnabled('base', false);
      expect(ok, false, reason: '有活跃依赖者必须拒绝');
      expect(manager.hasModule('base'), true);
      expect(manager.isInitialized('base'), true);
      expect(manager.isModuleEnabled('base'), true);
    });

    test('连点幂等：重复 disable/enable 无异常', () async {
      final manager = ModuleManager.instance;
      final module = TestModule(name: 'webdav');
      manager.registerKnownModules(() => [module]);
      await manager.registerModule(module);
      await manager.initializeModule('webdav');

      expect(await manager.setModuleEnabled('webdav', false), true);
      expect(await manager.setModuleEnabled('webdav', false), true,
          reason: '重复 disable 无操作');
      expect(await manager.setModuleEnabled('webdav', true), true);
      expect(await manager.setModuleEnabled('webdav', true), true);
      expect(manager.isInitialized('webdav'), true);
    });

    test('re-enable 从 known modules 查实例成功', () async {
      final manager = ModuleManager.instance;
      final module = TestModule(name: 'webdav');
      manager.registerKnownModules(() => [module]);
      await manager.registerModule(module);
      await manager.initializeModule('webdav');

      await manager.setModuleEnabled('webdav', false);
      expect(manager.hasModule('webdav'), false);

      final ok = await manager.setModuleEnabled('webdav', true);
      expect(ok, true);
      expect(manager.getModule('webdav'), same(module),
          reason: '从 known modules 查回同一实例');
      expect(manager.isInitialized('webdav'), true);
    });

    test('re-enable 时 known modules 查不到实例返回 false', () async {
      final manager = ModuleManager.instance;
      await manager.registerModule(TestModule(name: 'ghost'));
      await manager.initializeModule('ghost');

      await manager.setModuleEnabled('ghost', false);
      expect(manager.hasModule('ghost'), false);

      final ok = await manager.setModuleEnabled('ghost', true);
      expect(ok, false, reason: 'known modules 无此模块时拒绝启用');
      expect(manager.hasModule('ghost'), false);
    });
  });

  group('ModuleManager setModuleEnabled 异常后链复位', () {
    test('onInit 抛异常：错误向上抛出，链复位后后续 toggle 不卡死', () async {
      final manager = ModuleManager.instance;
      final module = _ExplodingModule();
      manager.registerKnownModules(() => [module]);

      await manager.setModuleEnabled('explode', false);
      await expectLater(
        manager.setModuleEnabled('explode', true),
        throwsA(isA<StateError>()),
        reason: 'onInit 异常必须向上抛出',
      );
      // 链已复位：异常后 disable 仍可执行（不卡死）
      expect(await manager.setModuleEnabled('explode', false), true);
    });

    test('仅首次 onInit 抛错：异常后再次启用可成功', () async {
      final manager = ModuleManager.instance;
      final module = _FailOnceModule();
      manager.registerKnownModules(() => [module]);

      await manager.setModuleEnabled('explode2', false);
      await expectLater(
        manager.setModuleEnabled('explode2', true),
        throwsA(isA<StateError>()),
      );
      await manager.setModuleEnabled('explode2', false);
      expect(await manager.setModuleEnabled('explode2', true), true,
          reason: '异常后链复位，可重试启用');
      expect(manager.isInitialized('explode2'), true);
      expect(module.registerCalls, 1);
    });
  });

  group('ModuleManager 服务绑定', () {
    test('bind/get 编译期绑定（0 损耗主路径）', () async {
      final manager = ModuleManager.instance;
      final service = TestService('A');

      manager.bind<ITestService>(service);
      expect(manager.hasService<ITestService>(), true);

      // 主路径：取一次引用后直接调用
      final ref = manager.get<ITestService>();
      expect(ref, same(service));
      expect(ref!.greet('world'), 'hello world from A');
      expect(ref.add(1, 2), 3);
      expect(ref.version, 'v1-A');
    });

    test('get 未注册返回 null，require 抛异常', () {
      final manager = ModuleManager.instance;
      expect(manager.get<ITestService>(), isNull);
      expect(
        () => manager.require<ITestService>(),
        throwsA(isA<StateError>()),
      );
    });

    test('unbind 后 get 返回 null', () {
      final manager = ModuleManager.instance;
      manager.bind<ITestService>(TestService('A'));
      manager.unbind<ITestService>();
      expect(manager.get<ITestService>(), isNull);
    });

    test('模块上下线联动服务绑定', () async {
      final manager = ModuleManager.instance;
      final module = TestModule(name: 'mod_svc');
      manager.injectContext(ModuleContext(
        config: null,
        bindService: (t, impl) => manager.bind<ITestService>(impl as ITestService),
        unbindService: (t) => manager.unbind<ITestService>(),
      ));
      // 模块 onRegister 中绑定服务（需 initializeModule 触发）
      final svcModule = _ServiceModule(manager);
      await manager.registerModule(svcModule);
      expect(manager.get<ITestService>(), isNull); // 仅登记未初始化

      await manager.initializeModule('svc_module');
      expect(manager.get<ITestService>(), isNotNull);

      await manager.unregisterModule('svc_module');
      expect(manager.get<ITestService>(), isNull);
    });
  });

  group('DynamicProxy 动态代理', () {
    test('代理转发到当前实现', () {
      var target = TestService('A');
      final proxy = _TestServiceProxy(() => target);

      expect(proxy.greet('x'), 'hello x from A');
      expect(proxy.add(2, 3), 5);
      expect(proxy.version, 'v1-A');
    });

    test('热插拔：切换实现后代理自动跟随', () {
      var target = TestService('A');
      final proxy = _TestServiceProxy(() => target);

      expect(proxy.greet('x'), 'hello x from A');
      target = TestService('B');
      expect(proxy.greet('x'), 'hello x from B');
    });

    test('目标未注册时使用 fallback', () {
      final proxy = _TestServiceProxy(
        () => null,
        fallback: TestService('FB'),
      );
      expect(proxy.greet('x'), 'hello x from FB');
    });

    test('目标未注册且无 fallback 抛异常', () {
      final proxy = _TestServiceProxy(() => null);
      expect(() => proxy.greet('x'), throwsA(isA<StateError>()));
    });

    test('调用计数', () {
      final proxy = _TestServiceProxy(() => TestService('A'));
      proxy.add(1, 1);
      proxy.add(2, 2);
      expect(proxy.invocationCount, 2);
    });
  });

  group('模块依赖排序初始化', () {
    test('依赖模块先于被依赖模块初始化', () async {
      final manager = ModuleManager.instance;
      final order = <String>[];

      await manager.registerModule(_OrderModule('app', ['base'], order));
      await manager.registerModule(_OrderModule('base', const [], order));

      await manager.initializeAll();
      expect(order, ['base', 'app'], reason: '依赖 base 必须先初始化');
    });

    test('initializeAll 分层并行：无依赖模块同层', () async {
      final manager = ModuleManager.instance;
      final order = <String>[];

      await manager.registerModule(_OrderModule('a', const [], order));
      await manager.registerModule(_OrderModule('b', const [], order));
      await manager.registerModule(_OrderModule('c', ['a', 'b'], order));

      await manager.initializeAll();
      // a、b 先于 c
      expect(order.indexOf('a'), lessThan(order.indexOf('c')));
      expect(order.indexOf('b'), lessThan(order.indexOf('c')));
    });

    test('initializeModule 单模块上线自动初始化依赖', () async {
      final manager = ModuleManager.instance;
      final order = <String>[];

      await manager.registerModule(_OrderModule('app', ['base'], order));
      await manager.registerModule(_OrderModule('base', const [], order));

      await manager.initializeModule('app');
      expect(order, ['base', 'app']);
      expect(manager.isInitialized('base'), true);
      expect(manager.isInitialized('app'), true);
    });

    test('initializeAll 幂等：重复调用不重复初始化', () async {
      final manager = ModuleManager.instance;
      final order = <String>[];

      await manager.registerModule(_OrderModule('app', ['base'], order));
      await manager.registerModule(_OrderModule('base', const [], order));

      await manager.initializeAll();
      await manager.initializeAll();
      expect(order, ['base', 'app']); // 不重复
    });

    test('循环依赖抛错', () async {
      final manager = ModuleManager.instance;
      await manager.registerModule(_OrderModule('a', ['b'], []));
      await manager.registerModule(_OrderModule('b', ['a'], []));

      expect(
        () => manager.initializeAll(),
        throwsA(isA<StateError>()),
      );
    });

    test('缺失依赖从已知清单自动补注册', () async {
      final manager = ModuleManager.instance;
      final order = <String>[];

      // 只注册 app，base 在已知清单中
      await manager.registerModule(_OrderModule('app', ['base'], order));
      manager.registerKnownModules(() => [_OrderModule('base', const [], order)]);

      await manager.initializeAll();
      expect(order, ['base', 'app']);
      expect(manager.hasModule('base'), true);
      expect(manager.isInitialized('base'), true);
    });

    test('服务类型依赖未满足时抛错', () async {
      final manager = ModuleManager.instance;
      await manager.registerModule(_ServiceDepModule());

      expect(
        () => manager.initializeModule('svc_dep'),
        throwsA(isA<StateError>()),
      );
    });
  });
}

/// 测试用动态代理
class _TestServiceProxy extends DynamicProxy implements ITestService {
  _TestServiceProxy(Object? Function() target, {Object? fallback}) {
    resolver = target;
    this.fallback = fallback;
    register('greet', (String name) => resolveT<ITestService>().greet(name));
    register('add', (int a, int b) => resolveT<ITestService>().add(a, b));
    // getter：无参处理器
    register('version', () => resolveT<ITestService>().version);
  }
}

/// 在 onRegister 绑定服务、onUnregister 解绑的模块
class _ServiceModule extends AppModule {
  _ServiceModule(this.manager);

  final ModuleManager manager;

  @override
  String get moduleName => 'svc_module';

  @override
  Future<void> onRegister(ModuleContext context) async {
    context.bindService!(ITestService, TestService('module'));
  }

  @override
  Future<void> onUnregister(ModuleContext context) async {
    context.unbindService!(ITestService);
  }
}

/// 上下线开关测试用模块：onRegister 绑定服务、onUnregister 解绑
class _ToggleServiceModule extends AppModule {
  _ToggleServiceModule({String? name}) : moduleName = name ?? 'toggle_svc';

  @override
  final String moduleName;

  int registerCalls = 0;
  int unregisterCalls = 0;

  @override
  Future<void> onRegister(ModuleContext context) async {
    registerCalls++;
    context.bindService!(ITestService, TestService('toggle'));
  }

  @override
  Future<void> onUnregister(ModuleContext context) async {
    unregisterCalls++;
    context.unbindService!(ITestService);
  }
}

/// 记录初始化顺序的模块
class _OrderModule extends AppModule {
  _OrderModule(this.moduleName, this.dependencies, this.order);

  @override
  final String moduleName;

  @override
  final List<String> dependencies;

  final List<String> order;

  @override
  Future<void> onInit(ModuleContext context) async {
    order.add(moduleName);
  }
}

/// 声明服务类型依赖（未绑定时初始化应抛错）
class _ServiceDepModule extends AppModule {
  @override
  String get moduleName => 'svc_dep';

  @override
  List<Type> get serviceDependencies => const [ITestService];

  @override
  Future<void> onInit(ModuleContext context) async {
    context.requireDependency<ITestService>();
  }
}

/// onInit 恒抛错的模块（验证异常后 toggle 链复位）
class _ExplodingModule extends AppModule {
  @override
  String get moduleName => 'explode';

  @override
  int get priority => 10;

  @override
  Future<void> onInit(ModuleContext context) async {
    throw StateError('onInit 爆炸');
  }
}

/// 仅首次 onInit 抛错的模块（验证异常后可重试启用）
class _FailOnceModule extends AppModule {
  int onInitCalls = 0;
  int registerCalls = 0;

  @override
  String get moduleName => 'explode2';

  @override
  int get priority => 10;

  @override
  Future<void> onInit(ModuleContext context) async {
    onInitCalls++;
    if (onInitCalls == 1) throw StateError('首次 onInit 抛错');
  }

  @override
  Future<void> onRegister(ModuleContext context) async {
    registerCalls++;
  }
}
