/// 服务容器 - 依赖注入容器
/// 管理应用中的所有服务和依赖关系
library;

import 'package:flutter/foundation.dart';
import 'package:gstore/core/exception/AppException.dart';

/// 服务生命周期
enum ServiceLifetime {
  /// 单例：整个应用生命周期内只创建一次
  singleton,

  /// 瞬态：每次请求都创建新实例
  transient,

  /// 作用域：在同一作用域内复用同一实例
  scoped,
}

/// 服务工厂函数
typedef ServiceFactory<T> = T Function(ServiceContainer container);

/// 服务描述符
class ServiceDescriptor<T> {
  /// 服务类型
  final Type serviceType;

  /// 工厂函数
  final ServiceFactory<T> factory;

  /// 生命周期
  final ServiceLifetime lifetime;

  /// 已创建的实例（单例模式）
  T? _instance;

  /// 作用域实例（作用域模式）
  T? _scopedInstance;

  ServiceDescriptor({
    required this.serviceType,
    required this.factory,
    required this.lifetime,
  });

  /// 获取或创建实例
  T getInstance(ServiceContainer container, [String? scopeId]) {
    switch (lifetime) {
      case ServiceLifetime.singleton:
        _instance ??= factory(container);
        return _instance!;

      case ServiceLifetime.transient:
        return factory(container);

      case ServiceLifetime.scoped:
        if (scopeId != null) {
          _scopedInstance ??= factory(container);
          return _scopedInstance!;
        }
        return factory(container);
    }
  }

  /// 清除作用域实例
  void clearScopedInstance() {
    _scopedInstance = null;
  }

  /// 清除单例实例（用于测试）
  void clearSingletonInstance() {
    _instance = null;
  }
}

/// 服务容器
class ServiceContainer {
  ServiceContainer._internal(this._parent);

  /// 创建根容器
  factory ServiceContainer.createRoot() {
    return ServiceContainer._internal(null);
  }

  /// 创建作用域容器
  ServiceContainer createScope([String? scopeId]) {
    return ServiceContainer._internal(this).._scopeId = scopeId ?? _generateScopeId();
  }

  /// 父容器
  final ServiceContainer? _parent;

  /// 作用域 ID
  String? _scopeId;

  /// 服务描述符
  final Map<Type, ServiceDescriptor> _services = {};

  /// 当前作用域的单例
  final Map<String, dynamic> _scopedSingletons = {};

  /// 生成作用域 ID
  static String _generateScopeId() {
    return 'scope_${DateTime.now().millisecondsSinceEpoch}_${Object().hashCode}';
  }

  /// ========== 服务注册 ==========

  /// 注册单例服务
  void registerSingleton<T>({
    required ServiceFactory<T> factory,
    Type? asType,
  }) {
    _register<T>(
      factory: factory,
      lifetime: ServiceLifetime.singleton,
      asType: asType,
    );
  }

  /// 注册瞬态服务
  void registerTransient<T>({
    required ServiceFactory<T> factory,
    Type? asType,
  }) {
    _register<T>(
      factory: factory,
      lifetime: ServiceLifetime.transient,
      asType: asType,
    );
  }

  /// 注册作用域服务
  void registerScoped<T>({
    required ServiceFactory<T> factory,
    Type? asType,
  }) {
    _register<T>(
      factory: factory,
      lifetime: ServiceLifetime.scoped,
      asType: asType,
    );
  }

  /// 注册实例（已创建的单例）
  void registerInstance<T>(T instance, {Type? asType}) {
    final type = asType ?? T;
    _services[type] = ServiceDescriptor<T>(
      serviceType: type,
      factory: (_) => instance,
      lifetime: ServiceLifetime.singleton,
    ).._instance = instance;
  }

  /// 通用注册方法
  void _register<T>({
    required ServiceFactory<T> factory,
    required ServiceLifetime lifetime,
    Type? asType,
  }) {
    final type = asType ?? T;
    if (_services.containsKey(type)) {
      debugPrint('ServiceContainer: 服务 $type 已存在，将被覆盖');
    }
    _services[type] = ServiceDescriptor<T>(
      serviceType: type,
      factory: factory,
      lifetime: lifetime,
    );
    debugPrint('ServiceContainer: 注册服务 $type ($lifetime)');
  }

  /// ========== 服务解析 ==========

  /// 获取服务
  T getService<T>() {
    final type = T;
    var descriptor = _services[type];

    // 如果当前容器没有，从父容器查找
    if (descriptor == null && _parent != null) {
      return _parent!.getService<T>();
    }

    if (descriptor == null) {
      throw ConfigurationException.missing(
        key: type.toString(),
        configPath: 'ServiceContainer',
      );
    }

    return descriptor.getInstance(this, _scopeId) as T;
  }

  /// 尝试获取服务
  T? tryGetService<T>() {
    try {
      return getService<T>();
    } catch (_) {
      return null;
    }
  }

  /// 检查服务是否已注册
  bool isRegistered<T>() {
    final type = T;
    return _services.containsKey(type) ||
        (_parent?.isRegistered<T>() ?? false);
  }

  /// ========== 生命周期管理 ==========

  /// 清除作用域
  void clearScope() {
    if (_scopeId == null) {
      debugPrint('ServiceContainer: 不是作用域容器，无法清除');
      return;
    }

    // 清除所有作用域服务
    for (final descriptor in _services.values) {
      descriptor.clearScopedInstance();
    }

    _scopedSingletons.clear();
    debugPrint('ServiceContainer: 清除作用域 $_scopeId');
  }

  /// 释放容器
  Future<void> dispose() async {
    // 清除作用域
    clearScope();

    // 清除所有单例（如果是根容器）
    if (_parent == null) {
      for (final descriptor in _services.values) {
        descriptor.clearSingletonInstance();
      }
      _services.clear();
      debugPrint('ServiceContainer: 容器已释放');
    }
  }

  /// ========== 批量操作 ==========

  /// 批量注册服务
  void registerBatch(Map<Type, ServiceFactory> factories, {
    ServiceLifetime lifetime = ServiceLifetime.singleton,
  }) {
    for (final entry in factories.entries) {
      _register(
        factory: entry.value,
        lifetime: lifetime,
        asType: entry.key,
      );
    }
  }

  /// 获取所有已注册的服务类型
  List<Type> getRegisteredTypes() {
    final types = _services.keys.toList();
    if (_parent != null) {
      types.addAll(_parent!.getRegisteredTypes());
    }
    return types.toSet().toList();
  }

  /// ========== 调试信息 ==========

  /// 打印所有注册的服务
  void printRegisteredServices() {
    debugPrint('========== 已注册的服务 ==========');
    debugPrint('容器: ${_scopeId ?? "根容器"}');

    for (final descriptor in _services.values) {
      final instanceInfo = descriptor._instance != null
          ? ' [已实例化]'
          : '';
      debugPrint('  ${descriptor.serviceType} (${descriptor.lifetime})$instanceInfo');
    }

    if (_parent != null) {
      debugPrint('\n父容器服务:');
      _parent!.printRegisteredServices();
    }

    debugPrint('==================================');
  }
}

/// 全局服务容器访问器
class ServiceLocator {
  ServiceLocator._internal();

  static final ServiceLocator _instance = ServiceLocator._internal();

  factory ServiceLocator() => _instance;

  /// 根容器
  ServiceContainer? _rootContainer;

  /// 当前作用域容器
  ServiceContainer? _currentScope;

  /// 初始化服务定位器
  void initialize({
    required void Function(ServiceContainer) registerServices,
  }) {
    _rootContainer = ServiceContainer.createRoot();
    registerServices(_rootContainer!);
    _currentScope = _rootContainer;

    if (kDebugMode) {
      _rootContainer!.printRegisteredServices();
    }
  }

  /// 获取当前容器
  ServiceContainer get currentContainer {
    if (_currentScope == null) {
      throw ConfigurationException(
        message: 'ServiceLocator 未初始化',
        code: 'SERVICE_LOCATOR_NOT_INITIALIZED',
      );
    }
    return _currentScope!;
  }

  /// 创建作用域
  ServiceContainer createScope([String? scopeId]) {
    if (_rootContainer == null) {
      throw ConfigurationException(
        message: 'ServiceLocator 未初始化',
        code: 'SERVICE_LOCATOR_NOT_INITIALIZED',
      );
    }
    return _rootContainer!.createScope(scopeId);
  }

  /// 进入作用域
  void enterScope(ServiceContainer scope) {
    _currentScope = scope;
  }

  /// 退出作用域
  void exitScope() {
    if (_currentScope != _rootContainer) {
      _currentScope!.clearScope();
      _currentScope = _rootContainer;
    }
  }

  /// 获取服务
  T get<T>() {
    return currentContainer.getService<T>();
  }

  /// 尝试获取服务
  T? tryGet<T>() {
    return currentContainer.tryGetService<T>();
  }

  /// 检查服务是否已注册
  bool isRegistered<T>() {
    return currentContainer.isRegistered<T>();
  }

  /// 重置服务定位器（用于测试）
  void reset() {
    _currentScope = null;
    _rootContainer = null;
  }

  /// 释放所有资源
  Future<void> dispose() async {
    if (_rootContainer != null) {
      await _rootContainer!.dispose();
    }
    reset();
  }
}

/// 服务定位器快捷方式
final serviceLocator = ServiceLocator();
