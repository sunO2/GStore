/// 动态代理层
///
/// 参考 Java 动态代理（Proxy + InvocationHandler）在 Dart 中的实现。
///
/// Dart 限制：
/// 1. `implements` 是编译期静态声明，无法 `implements T`（泛型参数）
/// 2. 无反射 API（dart:mirrors 在 Flutter 不可用），无法从 Symbol 动态调用
///
/// 因此动态代理采用"代理基类 + 方法处理器注册"模式：
/// ```dart
/// class AppStoreProxy extends DynamicProxy implements IAppStore {
///   AppStoreProxy(super.resolver) {
///     register('search', (String kw) => resolve()!.search(kw));
///   }
/// }
/// ```
/// [DynamicProxy.noSuchMethod] 拦截接口方法调用，从注册表查找处理器并
/// 通过 [Function.apply] 转发；处理器内部解析当前实现（模块热插拔支持）。
///
/// 使用场景（可选；主路径建议直接用 [ModuleManager.get] 编译期绑定，0 损耗）：
/// - AOP 拦截（日志/鉴权/埋点）
/// - 延迟绑定 / 模块热插拔时自动重取实现
/// - 对未上线模块提供降级行为
library;

/// 代理调用处理器（等价于 Java 的 InvocationHandler）
typedef ProxyHandler = Object? Function(
  Object proxy,
  Invocation invocation,
);

/// 动态代理基类
///
/// 具体代理类需 `extends DynamicProxy implements 某接口`，
/// 并在构造函数中为每个接口方法注册处理器。
class DynamicProxy {
  DynamicProxy();

  /// 解析当前目标实现的回调（未上线返回 null）
  Object? Function()? resolver;

  /// 降级实现（目标未注册时使用）
  Object? fallback;

  /// 方法处理器表（memberName → 处理器）
  final Map<Symbol, Function> _handlers = {};

  /// 调用计数（埋点/调试用）
  int invocationCount = 0;

  /// 注册方法处理器（位置参数 + 可选命名参数）
  void register(String name, Function handler) {
    _handlers[Symbol(name)] = handler;
  }

  /// 解析当前目标（resolver 优先，未注册返回 null）
  Object? resolve() => resolver?.call();

  /// 类型化解析（含 fallback；两者皆无抛 [StateError]）
  T resolveT<T>() {
    final t = resolver?.call();
    if (t != null) return t as T;
    final fb = fallback;
    if (fb != null) return fb as T;
    throw StateError('模块服务 $T 未注册（模块未上线或已下线）');
  }

  /// 拦截全部接口方法调用
  @override
  dynamic noSuchMethod(Invocation invocation) {
    invocationCount++;
    final handler = _handlers[invocation.memberName];
    if (handler == null) {
      return _handleUnknown(invocation);
    }
    return Function.apply(
      handler,
      invocation.positionalArguments,
      invocation.namedArguments,
    );
  }

  /// 未知方法处理：目标有真实实现时动态派发，否则 fallback/抛错
  Object? _handleUnknown(Invocation invocation) {
    final target = resolve();
    if (target != null) {
      // Dart 无反射：对已知接口方法走 handler；未知成员尝试 dynamic 派发
      // （仅当目标也实现了 noSuchMethod 时有效）
      try {
        return (target as dynamic).noSuchMethod(invocation);
      } catch (_) {
        // 目标无 noSuchMethod（普通类）→ 走 fallback
      }
    }
    final fb = fallback;
    if (fb != null) {
      try {
        return (fb as dynamic).noSuchMethod(invocation);
      } catch (_) {
        // fallback 也是普通类
      }
    }
    throw StateError(
        '模块服务未注册（模块未上线或已下线）：$runtimeType.$invocation');
  }

  @override
  String toString() => 'DynamicProxy<$runtimeType>';

  @override
  int get hashCode => Object.hash(runtimeType, resolver);

  @override
  bool operator ==(Object other) =>
      other is DynamicProxy && other.resolver == resolver;
}
