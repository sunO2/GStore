/// 模块注册中心
///
/// 管理应用模块的注册（上线）、注销（下线）、查询、依赖排序初始化与事件通知。
///
/// 模块依赖注入式初始化（类似 Linux 包管理器）：
/// - 模块通过 [AppModule.dependencies]（模块名）与 [AppModule.serviceDependencies]（服务类型）
///   声明依赖
/// - [initializeAll] 按拓扑排序分层初始化：依赖满足的模块同层并行（Future.wait），
///   依赖就绪后才初始化下一层
/// - [initializeModule] 单模块上线：自动递归补注册/初始化其依赖（apt 自动装依赖）
/// - 环检测：循环依赖抛错并输出依赖链
///
/// 性能设计（"几乎 0 损耗"）：
/// - 主路径：调用方在初始化时通过 [get]/[require] 取一次实现引用，
///   后续方法调用为编译期接口绑定（仅一次 O(1) Map 查找）。
/// - 热插拔：模块上下线通过 [onChange] 事件通知调用方重取或降级；
///   [ModuleProxy] 提供可选的运行期动态代理（拦截/延迟绑定）。
library;

import 'dart:async';

import 'module.dart';
import 'module_event.dart';

/// 模块注册中心（单例）
class ModuleManager {
  ModuleManager._internal();

  static ModuleManager? _instance;
  static ModuleManager get instance => _instance ??= ModuleManager._internal();

  /// 已注册模块（moduleName → module）
  final Map<String, AppModule> _modules = {};

  /// 已初始化模块（moduleName → true）
  final Set<String> _initialized = {};

  /// 服务接口绑定（Type → 实现）
  final Map<Type, Object> _services = {};

  /// 内置模块清单（自动补注册依赖时查找）
  List<AppModule> Function()? _knownModulesProvider;

  /// 模块上下线事件控制器
  final _changeController = StreamController<ModuleEvent>.broadcast();

  /// 模块上下线事件流
  Stream<ModuleEvent> get onChange => _changeController.stream;

  /// 模块上下文（注入 Agent 工具/服务绑定回调，由外部初始化）
  ModuleContext? _context;

  /// 注入模块上下文（配置/工具/服务联动能力；null 清除）
  void injectContext(ModuleContext? context) {
    _context = context;
  }

  /// 当前模块上下文
  ModuleContext? get context => _context;

  /// 注册内置模块清单提供器（自动补注册依赖时从清单查找未注册模块）
  void registerKnownModules(List<AppModule> Function() provider) {
    _knownModulesProvider = provider;
  }

  /// 注册模块（登记 + 发事件；初始化由 initializeAll/initializeModule 驱动）
  Future<void> registerModule(AppModule module) async {
    final name = module.moduleName;
    if (_modules.containsKey(name)) {
      await unregisterModule(name);
    }
    _modules[name] = module;
    _initialized.remove(name);
    _emit(name, ModuleLifecycle.registered);
  }

  /// 注册并初始化模块（热插拔上线一步完成，自动补注册/初始化依赖）
  Future<void> activate(AppModule module) async {
    await registerModule(module);
    await initializeModule(module.moduleName);
  }

  /// 注销模块（下线；未注册时忽略）
  Future<void> unregisterModule(String moduleName) async {
    final module = _modules.remove(moduleName);
    if (module == null) return;
    _initialized.remove(moduleName);
    await module.onUnregister(_context ?? ModuleContext(config: null));
    _emit(moduleName, ModuleLifecycle.unregistered);
  }

  /// 是否已注册指定模块
  bool hasModule(String moduleName) => _modules.containsKey(moduleName);

  /// 已注册模块名列表
  List<String> get moduleNames => _modules.keys.toList();

  /// 已注册模块数量
  int get moduleCount => _modules.length;

  /// 获取模块实例
  AppModule? getModule(String moduleName) => _modules[moduleName];

  /// 模块是否已初始化完成
  bool isInitialized(String moduleName) => _initialized.contains(moduleName);

  /// 初始化全部已注册模块：自动补注册缺失依赖 + 拓扑排序分层并行
  ///
  /// 依赖满足的模块同层 Future.wait 并行；层间按依赖顺序。
  /// 循环依赖抛 StateError。
  Future<void> initializeAll() async {
    // 自动补注册：把已注册模块声明的、但未注册的依赖模块从已知清单补上
    _autoRegisterMissingDependencies();

    // 环检测
    _detectCycles();

    // 分层拓扑排序 + 层内并行
    final layers = _topologicalLayers();
    for (final layer in layers) {
      await Future.wait(layer.map(_initModule));
    }
  }

  /// 初始化指定模块（热插拔上线）：自动递归补注册/初始化其依赖
  Future<void> initializeModule(String moduleName) async {
    _autoRegisterMissingDependencies();
    await _initModule(moduleName);
  }

  /// 补注册缺失依赖模块（从已知清单）
  void _autoRegisterMissingDependencies() {
    final provider = _knownModulesProvider;
    if (provider == null) return;
    final known = provider();
    var changed = true;
    // 迭代：补注册的模块可能又引入新依赖
    while (changed) {
      changed = false;
      for (final module in _modules.values.toList()) {
        for (final dep in module.dependencies) {
          if (!_modules.containsKey(dep)) {
            final found = known.where((m) => m.moduleName == dep).toList();
            if (found.isNotEmpty) {
              _modules[dep] = found.first;
              changed = true;
            }
          }
        }
      }
    }
  }

  /// 单模块初始化（递归解析依赖）
  Future<void> _initModule(String name) async {
    final module = _modules[name];
    if (module == null) {
      throw StateError('模块 $name 未注册');
    }
    if (_initialized.contains(name)) return;

    // 递归初始化依赖（模块名依赖）
    for (final dep in module.dependencies) {
      if (!_initialized.contains(dep)) {
        await _initModule(dep);
      }
    }
    // 服务类型依赖：若未绑定且清单中有对应模块，尝试解析
    for (final serviceType in module.serviceDependencies) {
      if (!_services.containsKey(serviceType)) {
        throw StateError(
            '模块 ${module.moduleName} 的服务依赖 $serviceType 未绑定');
      }
    }

    final ctx = _context ?? ModuleContext(config: null, manager: this);
    // 自身初始化 → 绑定（原子完成）
    await module.onInit(ctx);
    await module.onRegister(ctx);
    _initialized.add(name);
  }

  /// 拓扑分层：返回按依赖深度分层的模块名列表（同层内按 priority 排序）
  ///
  /// 每层内的模块依赖均已不在 remaining（即已被更早层处理或本就未注册）。
  List<List<String>> _topologicalLayers() {
    final layers = <List<String>>[];
    final remaining = Map<String, AppModule>.from(_modules);

    while (remaining.isNotEmpty) {
      // 依赖全部已被处理（不在 remaining）的模块进入本层
      final ready = remaining.entries
          .where((e) => e.value.dependencies.every((d) => !remaining.containsKey(d)))
          .toList()
        ..sort((a, b) => a.value.priority.compareTo(b.value.priority));

      if (ready.isEmpty) {
        final blocked = remaining.keys.join(', ');
        throw StateError('模块依赖无法满足（可能缺失依赖模块）: $blocked');
      }

      final layer = ready.map((e) => e.key).toList();
      layers.add(layer);
      for (final name in layer) {
        remaining.remove(name);
      }
    }
    return layers;
  }

  /// 检测循环依赖（DFS）
  void _detectCycles() {
    final visiting = <String>{};
    final visited = <String>{};

    void dfs(String name, List<String> chain) {
      if (visiting.contains(name)) {
        final start = chain.indexOf(name);
        final cycle = [...chain.sublist(start), name];
        throw StateError('检测到模块循环依赖: ${cycle.join(' → ')}');
      }
      if (visited.contains(name)) return;
      visiting.add(name);
      chain.add(name);
      final module = _modules[name];
      if (module != null) {
        for (final dep in module.dependencies) {
          if (_modules.containsKey(dep)) {
            dfs(dep, chain);
          }
        }
      }
      chain.removeLast();
      visiting.remove(name);
      visited.add(name);
    }

    for (final name in _modules.keys) {
      dfs(name, []);
    }
  }

  /// 获取服务实现（未注册返回 null）
  ///
  /// 主路径性能入口：调用方缓存返回值后直接调用接口方法。
  T? get<T>() {
    final impl = _services[T];
    return impl is T ? impl : null;
  }

  /// 获取服务实现（未注册抛异常）
  T require<T>() {
    final impl = get<T>();
    if (impl == null) {
      throw StateError('服务 $T 未注册（模块可能未上线或已下线）');
    }
    return impl;
  }

  /// 绑定服务实现（模块上线时调用）
  void bind<T>(T impl) {
    _services[T] = impl as Object;
  }

  /// 按运行时类型绑定（供 ModuleContext.bindService 回调使用）
  void bindByType(Type type, Object impl) {
    _services[type] = impl;
  }

  /// 解绑服务实现（模块下线时调用）
  void unbind<T>() {
    _services.remove(T);
  }

  /// 按运行时类型解绑（供 ModuleContext.unbindService 回调使用）
  void unbindByType(Type type) {
    _services.remove(type);
  }

  /// 是否已绑定服务
  bool hasService<T>() => _services.containsKey(T);

  /// 已绑定的服务类型列表
  List<Type> get serviceTypes => _services.keys.toList();

  void _emit(String moduleName, ModuleLifecycle lifecycle) {
    if (_changeController.isClosed) return;
    _changeController.add(ModuleEvent(
      moduleName: moduleName,
      lifecycle: lifecycle,
    ));
  }

  /// 清空全部模块与服务（测试/重置用）
  Future<void> clear() async {
    final names = _modules.keys.toList();
    for (final name in names) {
      await unregisterModule(name);
    }
    _services.clear();
    _initialized.clear();
  }

  /// 释放资源
  void dispose() {
    _changeController.close();
  }
}
