/// 模块注册中心
///
/// 管理应用模块的注册（上线）、注销（下线）、查询与事件通知。
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

  /// 服务接口绑定（Type → 实现）
  final Map<Type, Object> _services = {};

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

  /// 注册模块（上线，幂等：同名模块先下线再重新上线）
  Future<void> registerModule(AppModule module) async {
    final name = module.moduleName;
    if (_modules.containsKey(name)) {
      await unregisterModule(name);
    }
    _modules[name] = module;
    _emit(name, ModuleLifecycle.registered);
    // 生命周期钩子始终调用（context 为 null 时模块自行降级处理）
    await module.onRegister(_context ?? ModuleContext(config: null));
  }

  /// 注销模块（下线；未注册时忽略）
  Future<void> unregisterModule(String moduleName) async {
    final module = _modules.remove(moduleName);
    if (module == null) return;
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
  }

  /// 释放资源
  void dispose() {
    _changeController.close();
  }
}
