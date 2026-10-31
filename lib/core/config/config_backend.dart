/// `ConfigStore` 的后端接缝。
///
/// [ConfigStore] 只是兼容适配器：key 解析、JSON 兼容、敏感标记与事件映射都在
/// 适配器层完成；真正的读写/订阅由本接缝的实现提供：
/// * [RustConfigBackend]：生产实现，委托 Rust 权威存储（经 `ConfigService`）。
/// * `MemoryConfigBackend`（见 `config_memory_backend.dart`）：测试/无 Rust
///   环境下的内存 fake，经 `ConfigApiClient` 注入 `ConfigService`。
///
/// 所有方法都接收**已解析的 wire key**；调用方保证 key 已注册且非空。
/// 读取是 **raw**（不脱敏，C3 可信应用内读取）；事件由后端保证已脱敏。
library;

import 'config_service.dart';

/// 配置后端接缝。
abstract class ConfigBackend {
  /// 初始化后端（幂等由 [ConfigStore] 负责）。
  Future<void> initialize();

  /// 原始读取（敏感项也返回明文，仅可信应用内使用；绝不写日志）。
  Future<Object?> read(String wireKey);

  /// 写入（返回是否成功）。
  Future<bool> write(String wireKey, Object? value);

  /// 删除（返回是否成功）。
  Future<bool> remove(String wireKey);

  /// 是否存在**显式写入**的值（注册默认值不算存在）。
  Future<bool> contains(String wireKey);

  /// 单个 key 的过滤变化流（过滤下推到 Rust / fake client）。
  Stream<ConfigChangeEvent> watch(String wireKey);

  /// 全局变化流（仅用于兼容 [ConfigStore.changes]）。
  Stream<ConfigChangeEvent> get changes;
}

/// 生产后端：委托 Rust 权威配置（`ConfigService`）。
///
/// 读取使用 `getRaw`（`ConfigApi.get(masked:false)`），因此不会拿到
/// `get` 的 `***` 脱敏默认值；写入/删除/订阅全部走 Rust 校验与过滤。
class RustConfigBackend implements ConfigBackend {
  const RustConfigBackend();

  @override
  Future<void> initialize() async {
    // 惰性：真正的 `ConfigApi.init()` 由 `ConfigService.ensureReady()` 在首次
    // 操作时执行（生产启动早期 `CoreApi` 可能尚未就绪）。
  }

  @override
  Future<Object?> read(String wireKey) =>
      ConfigService.instance.getRaw(wireKey);

  @override
  Future<bool> write(String wireKey, Object? value) async {
    final result = await ConfigService.instance.set(wireKey, value);
    return result.success;
  }

  @override
  Future<bool> remove(String wireKey) async {
    final result = await ConfigService.instance.clear(wireKey);
    return result.success;
  }

  @override
  Future<bool> contains(String wireKey) async {
    final snapshot = await ConfigService.instance.snapshot(wireKey);
    return snapshot?.value != null;
  }

  @override
  Stream<ConfigChangeEvent> watch(String wireKey) =>
      ConfigService.instance.watch(wireKey);

  @override
  Stream<ConfigChangeEvent> get changes => ConfigService.instance.onChange;
}
