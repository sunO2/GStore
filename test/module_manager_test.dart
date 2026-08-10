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

    test('同名模块重复注册 = 重新上线（触发 onRegister）', () async {
      final manager = ModuleManager.instance;
      final m1 = TestModule(name: 'mod_a');
      final m2 = TestModule(name: 'mod_a');

      await manager.registerModule(m1);
      await manager.registerModule(m2);

      expect(m1.unregisterCalls, 1); // 旧模块被下线
      expect(m2.registerCalls, 1); // 新模块上线
      expect(manager.getModule('mod_a'), same(m2));
    });

    test('生命周期钩子按上线/下线调用', () async {
      final manager = ModuleManager.instance;
      final module = TestModule(name: 'mod_a');
      await manager.registerModule(module);
      expect(module.registerCalls, 1);

      await manager.unregisterModule('mod_a');
      expect(module.unregisterCalls, 1);
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
      // 模块 onRegister 中绑定服务
      final svcModule = _ServiceModule(manager);
      await manager.registerModule(svcModule);
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
