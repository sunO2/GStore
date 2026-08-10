/// 模块化框架
///
/// GStore 模块化体系核心：模块注册中心 + 生命周期钩子 + 动态代理。
///
/// 设计目标（参考 Java 动态代理思想，兼顾 Dart 特性）：
/// - **不直接调用模块组件功能**：通过 [ModuleManager] 注册表获取实现（接口引用），
///   或通过 [DynamicProxy] 动态代理转发调用
/// - **热插拔**：模块上线注册到 [ModuleManager]，下线移除
/// - **性能几乎 0 损耗**：主路径为编译期接口调用（O(1) Map 查找一次缓存），
///   动态代理仅用于需要运行期拦截/延迟绑定的场景
///
/// 模块上下线联动：配置（ConfigModule）、Agent 工具、服务接口三合一，
/// 通过 [AppModule.onRegister]/[AppModule.onUnregister] 生命周期钩子管理。
library;

export 'module_base.dart';
export 'module_event.dart';
export 'module_manager.dart';
export 'module_proxy.dart';
