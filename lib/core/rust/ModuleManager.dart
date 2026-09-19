import 'dart:async' show unawaited, StreamController;
import 'dart:convert' show base64Encode, jsonEncode, utf8;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;

import 'package:gstore/core/event/app_event.dart';
import 'package:gstore/core/logger/LogManager.dart';
import 'package:gstore/core/rust/ModuleBootstrap.dart';
import 'package:gstore/core/rust/ModuleContext.dart';
import 'package:gstore/core/rust/ModuleLoader.dart' show ModuleProgressCallback;
import 'package:gstore/core/rust/RustBridge.dart';
import 'package:gstore/core/rust/contract/GStoreException.dart';
import 'package:gstore/core/rust/generated/bridge.dart'
    show EventBridge, HostInspector, LogBridge, ModuleHandle;
import 'package:gstore/core/rust/generated/contract/envelope.pb.dart';
import 'package:gstore/core/rust/generated/event_bridge.dart'
    show ModuleEvent;
import 'package:gstore/core/rust/generated/log_bridge.dart' show LogMessage;
import 'package:gstore/core/rust/generated/manager.dart' show ModuleInfo;

/// 模块事件回调（架构文档 6.8：Dart 侧订阅模块推送的事件，如进度/流式）
typedef ModuleEventHandler = void Function(ModuleEvent event);

/// 模块管理门面（架构文档第 5/6 章）
///
/// 封装 Rust 侧 ModuleHandle/InstanceHandle，向业务层提供统一的模块加载、
/// 实例创建与调用入口；并负责把 Rust 日志流订阅到 [LogManager]。
///
/// P3 起提供统一 `callModule`：信封编解码 + 状态码→异常映射 + 请求 ID 埋点，
/// 所有模块域（repo/qr/analyzer）共用此入口，错误规则单点定义。
class RustModuleManager {
  RustModuleManager._();

  static RustModuleManager? _instance;

  static RustModuleManager get instance =>
      _instance ??= RustModuleManager._();

  static final Map<String, ModuleHandle> _handles = {};
  static bool _logSubscribed = false;
  static bool _eventSubscribed = false;
  static bool _bridgesReset = false;
  static int _requestCounter = 0;
  static ModuleEventHandler? _moduleEventHandler;

  // ---- callModule 自愈测试接缝（生产未配置覆盖时行为不变） ----

  /// 句柄加载覆盖（生产默认：[loadModule]）。
  static Future<ModuleHandle> Function(String name)? _loadModuleOverride;

  /// 安装确保覆盖（生产默认：[ModuleBootstrap.ensureOnly]）。
  static Future<bool> Function(
    String name, {
    bool allowDownload,
    ModuleProgressCallback? onProgress,
  })? _ensureOverride;

  /// 句柄缓存写入观察钩子（默认仅写 [_handles]）。
  static void Function(String name, ModuleHandle handle)? _seedHandleOverride;

  /// readiness 覆盖（生产默认：[ensureReady]；测试用于绕过 FFI 初始化）。
  static Future<void> Function()? _ensureReadyOverride;

  static final StreamController<ModuleEvent> _eventController =
      StreamController<ModuleEvent>.broadcast();

  /// 事件桥实例（订阅时创建，供下行 broadcast 复用）
  static EventBridge? _eventBridge;

  /// 模块事件广播流（进度/流式等；业务层可多处订阅）
  Stream<ModuleEvent> get moduleEvents => _eventController.stream;

  /// 注册模块事件处理器（业务层订阅模块推送的事件，如下载进度）
  void setModuleEventHandler(ModuleEventHandler handler) {
    _moduleEventHandler = handler;
  }

  /// 确保 bridge 初始化 + 日志订阅（幂等，可多次调用）
  Future<void> ensureReady() async {
    final readyOverride = _ensureReadyOverride;
    if (readyOverride != null) {
      await readyOverride();
      return;
    }
    await RustBridge.ensureInitialized();

    // 引擎在同进程内被销毁重建时，宿主仍持有指向上一个 isolate 的失效 StreamSink。
    // 新 isolate 在本轮订阅前清空它们，避免向已销毁端口推送（二次启动崩溃的次因）。
    if (!_bridgesReset) {
      _bridgesReset = true;
      try {
        final inspector = await HostInspector.newInstance();
        await inspector.resetBridges();
      } catch (e) {
        appLog.warning('RustModuleManager: 重置桥接 sink 失败 - $e');
      }
    }

    if (!_logSubscribed) {
      _logSubscribed = true;
      unawaited(_subscribeLogs());
    }
    if (!_eventSubscribed) {
      _eventSubscribed = true;
      unawaited(_subscribeEvents());
    }
  }

  /// 预注册常驻模块（架构文档 4.4 preload）：加载并保持句柄引用，
  /// Rust 侧以 persistent 常驻（repo 等有状态核心域，refcount 归零也不卸载）。
  /// 幂等：已加载的模块跳过。
  Future<void> preloadModules(List<String> names) async {
    for (final name in names) {
      try {
        await loadModule(name);
      } catch (e) {
        appLog.warning('RustModuleManager: 预注册模块 $name 失败 - $e');
      }
    }
  }

  /// 统一模块调用入口（架构文档 6.6）：构造信封 → 路由 → 解包 → 异常映射。
  ///
  /// [module] 目标模块名，[instance] 实例句柄（null = 静态调用），
  /// [method] 域内方法名，[payload] 域 schema 编码后的字节。
  /// 成功返回响应 payload 字节；失败抛 [GStoreException] 分层异常。
  Future<Uint8List> callModule(
    String module,
    String? instance,
    String method,
    Uint8List payload, {
    int? timeoutMs,
    String? requestId,
  }) async {
    await ensureReady();
    final reqId = requestId ??
        'req_${DateTime.now().microsecondsSinceEpoch}_${_requestCounter++}';
    final request = EnvelopeRequest(
      protocolVersion: 1,
      module: module,
      instance: instance ?? '',
      method: method,
      requestId: reqId,
      payload: payload,
    );

    final handle = await _loadOrEnsure(module);
    final respBytes = timeoutMs == null
        ? await handle.callEnvelope(requestBytes: request.writeToBuffer())
        : await handle.callEnvelopeTimed(
            requestBytes: request.writeToBuffer(),
            timeoutMs: BigInt.from(timeoutMs),
          );
    final response = EnvelopeResponse.fromBuffer(respBytes);

    if (response.status.value == 200) {
      return Uint8List.fromList(response.payload);
    }

    // 统一状态码→异常映射 + 日志埋点
    final status = response.status;
    final exception = statusCodeToException(
      status: status,
      errorCode: response.errorCode.isEmpty ? 'UNKNOWN' : response.errorCode,
      message: response.errorMessage,
      requestId: reqId,
    );
    appLog.warning(
        '[CallModule] $module.$method -> ${exception.status.name} $reqId: ${exception.errorCode} ${exception.message}');
    throw exception;
  }

  /// 取消某次在途调用（requestId 需与 callModule 传入/生成的一致）。
  /// 模块未实现 cancel（如无长任务的 qr/analyzer）则为无操作。
  Future<void> cancelCall(String module, String requestId) async {
    final handle = _handles[module];
    if (handle == null) return;
    try {
      await handle.cancelCall(requestId: requestId);
    } catch (e) {
      appLog.warning('RustModuleManager: cancelCall($module, $requestId) 失败 - $e');
    }
  }

  /// 加载模块（幂等：已注册则复用句柄，refcount+1 由 Rust 侧管理）
  Future<ModuleHandle> loadModule(String name) async {
    await ensureReady();
    final existing = _handles[name];
    if (existing != null) return existing;
    final handle = await ModuleHandle.load(moduleName: name);
    _handles[name] = handle;
    return handle;
  }

  /// 加载句柄，失败时对 **自动策略** 模块执行一次 `MODULE_NOT_FOUND` 自愈。
  ///
  /// 流程：缓存 → 加载；加载抛错后：
  /// 1. 若模块策略非 [ModuleInstallPolicy.auto]（如 `llm`）→ 立即重抛，
  ///    确认策略绝不静默自动安装；
  /// 2. 否则经门 [ModuleBootstrap.ensureOnly] 补装；补装返回 `false` → 重抛
  ///    **原始错误**（不吞错）；
  /// 3. 补装成功后优先复用 ensure 挂载写入缓存的句柄，仍无则再加载一次
  ///    （至多一次，无循环）。成功自愈记录一条 info 日志。
  ///
  /// 注意：宿主 [ModuleHandle.load] 的失败值是**裸 `String`**（非
  /// `GStoreException`），故此处按任意 [Object] 泛化捕获，不依赖错误码。
  Future<ModuleHandle> _loadOrEnsure(String name) async {
    final cached = _handles[name];
    if (cached != null) return cached;

    final loadOverride = _loadModuleOverride;
    try {
      return loadOverride != null ? await loadOverride(name) : await loadModule(name);
    } catch (_) {
      if (ModuleBootstrap.instance.policyFor(name) != ModuleInstallPolicy.auto) {
        // llm 等确认策略：绝不因一次调用失败而自动安装。
        rethrow;
      }

      final ensureOverride = _ensureOverride;
      final healed = ensureOverride != null
          ? await ensureOverride(name, allowDownload: true)
          : await ModuleBootstrap.instance.ensureOnly(name);
      if (!healed) {
        // 原错误原样传播（可能是裸 String）。
        rethrow;
      }

      // ensure 挂载可能已把句柄写入缓存；有则直接复用，无需二次加载。
      final seeded = _handles[name];
      final handle = seeded ??
          (loadOverride != null ? await loadOverride(name) : await loadModule(name));
      if (seeded == null) {
        _seedHandle(name, handle);
      }
      // 成功自愈只在单一出口记录一次日志（失败路径不经过此处）。
      appLog.info('[CallModule] ensured $name after MODULE_NOT_FOUND');
      return handle;
    }
  }

  /// 写入模块句柄缓存：默认写真实缓存 [_handles]，并在注入钩子时通知观察者。
  void _seedHandle(String name, ModuleHandle handle) {
    _handles[name] = handle;
    _seedHandleOverride?.call(name, handle);
  }

  /// 模块是否已加载（查询 Rust 侧注册表）
  Future<bool> isLoaded(String name) async {
    await ensureReady();
    final handle = _handles[name];
    if (handle == null) return false;
    return handle.isLoaded();
  }

  /// 宿主已加载的原生插件快照（只读诊断；查宿主注册表，不触发模块加载）
  Future<List<ModuleInfo>> loadedModules() async {
    await ensureReady();
    final inspector = await HostInspector.newInstance();
    return inspector.loadedModules();
  }

  /// 释放模块引用（业务层一般无需调用，模块常驻）
  Future<void> releaseModule(String name) async {
    final handle = _handles.remove(name);
    if (handle != null) {
      await handle.dispose();
    }
  }

  /// 从 .so 动态挂载模块（P2 按需下载后调用）。返回句柄，失败返回 null。
  Future<ModuleHandle?> mountFromSo(String soPath) async {
    await ensureReady();
    try {
      final handle = await ModuleHandle.mountFromSo(soPath: soPath);
      // 统一以模块名为 key（与 loadModule/isLoaded/releaseModule 一致），
      // 避免同一模块在 name 与 soPath 两个 key 下重复持有句柄造成泄漏。
      final name = _moduleNameFromSoPath(soPath);
      if (name != null) {
        _handles.putIfAbsent(name, () => handle);
      } else {
        _handles.putIfAbsent(soPath, () => handle);
      }
      return handle;
    } catch (e) {
      appLog.error('RustModuleManager: mountFromSo($soPath) 失败 - $e');
      return null;
    }
  }

  /// 从 .so 路径解析模块名。
  ///
  /// 命名约定：`libgstore_mod_<name>[_<major>.<minor>.<patch>].so`，其中版本段
  /// **恒为三段纯数字**（与 `RustModuleLoader` 本地落盘命名一致；不得带 ABI 后缀
  /// 或 `+build`/预发布段）。三段式正则保证 `mountFromSo` 后
  /// `_handles`/`isLoaded(name)` 对已下载模块成立。
  static final RegExp _soNamePattern =
      RegExp(r'^libgstore_mod_([a-z0-9_]+?)(?:_(\d+)\.(\d+)\.(\d+))?\.so$');

  static String? _moduleNameFromSoPath(String soPath) {
    final base = p.basename(soPath);
    return _soNamePattern.firstMatch(base)?.group(1);
  }

  /// 测试专用：暴露 `.so` 路径 → 模块名解析（三段式命名契约验证）。
  @visibleForTesting
  static String? debugModuleNameFromSoPath(String soPath) =>
      _moduleNameFromSoPath(soPath);

  /// 配置 `callModule` 自愈测试接缝（生产未配置覆盖时行为不变）。
  ///
  /// * [loadModuleOverride] 默认 [loadModule]；
  /// * [ensureOverride] 默认 [ModuleBootstrap.instance.ensureOnly]；
  /// * [seedHandle] 在写入 [_handles] 后触发（默认无钩子），供测试观察；
  /// * [readyOverride] 默认 [ensureReady]（测试用于绕过 FFI 初始化）。
  @visibleForTesting
  void debugConfigure({
    Future<ModuleHandle> Function(String name)? loadModuleOverride,
    Future<bool> Function(
      String name, {
      bool allowDownload,
      ModuleProgressCallback? onProgress,
    })? ensureOverride,
    void Function(String name, ModuleHandle handle)? seedHandle,
    Future<void> Function()? readyOverride,
  }) {
    _loadModuleOverride = loadModuleOverride;
    _ensureOverride = ensureOverride;
    _seedHandleOverride = seedHandle;
    _ensureReadyOverride = readyOverride;
  }

  /// 清除 `callModule` 自愈的全部测试覆盖。
  @visibleForTesting
  void debugReset() {
    _loadModuleOverride = null;
    _ensureOverride = null;
    _seedHandleOverride = null;
    _ensureReadyOverride = null;
  }

  /// 测试专用：模拟 ensure/挂载把句柄写入真实缓存（见 [_seedHandle]）。
  @visibleForTesting
  void debugSeedHandle(String name, ModuleHandle handle) =>
      _seedHandle(name, handle);

  /// 订阅 Rust 日志流到 LogManager（Rust 日志可在日志查看器中查看）
  Future<void> _subscribeLogs() async {
    final bridge = await LogBridge.newInstance();
    bridge.logsStream().listen(_handleLogMessage);
  }

  /// 订阅模块事件流（模块经 emit_event 推送的事件，转发给注册的处理器 + 广播流），
  /// 并把上行事件接入统一 AppEventBus；同时注册下行 sink（AppEventBus → 模块）。
  Future<void> _subscribeEvents() async {
    final bridge = await EventBridge.newInstance();
    _eventBridge = bridge;
    bridge.eventsStream().listen((event) {
      _moduleEventHandler?.call(event);
      if (!_eventController.isClosed) {
        _eventController.add(event);
      }
      // 上行接入统一事件总线
      AppEventBus.instance.publish(AppEvent(
        type: AppEventTypes.rustEvent,
        source: AppEventSource.rust,
        data: {
          'eventType': event.eventType,
          'moduleId': event.moduleId.toString(),
          'instanceId': event.instanceId.toString(),
          'data': base64Encode(event.data),
        },
      ));
      appLog.debug(
          '[ModuleEvent] ${event.eventType} module=${event.moduleId} instance=${event.instanceId}');
    });

    // 下行：统一总线中标记 downlink 的事件 → 广播给所有已加载 Rust 模块
    AppEventBus.instance.registerDownlinkSink((evt) {
      unawaited(broadcastEvent(evt));
    });
  }

  /// 应用事件下行：广播给所有已加载 Rust 模块（模块经 ABI `on_event` 订阅）
  Future<void> broadcastEvent(AppEvent event) async {
    final bridge = _eventBridge;
    if (bridge == null) return;
    try {
      final payload =
          Uint8List.fromList(utf8.encode(jsonEncode(event.data ?? const {})));
      await bridge.broadcast(kind: event.type, data: payload);
    } catch (e) {
      appLog.warning('RustModuleManager: 下行事件 ${event.type} 失败 - $e');
    }
  }

  void _handleLogMessage(LogMessage msg) {
    final level = _mapLevel(msg.level);
    // Rust 统一日志接口：target 统一加 RUST- 前缀（如 [RUST-rust]），
    // 便于在日志页用 "RUST-" 关键字筛出全部 Rust 日志。
    final module = msg.module.isEmpty ? 'rust' : msg.module;
    final message = '[RUST-$module] ${msg.message}';
    LogManager.instance.log(level: level, message: message);
  }

  LogLevel _mapLevel(int level) {
    switch (level) {
      case 0:
        return LogLevel.debug;
      case 2:
        return LogLevel.warning;
      case 3:
        return LogLevel.error;
      default:
        return LogLevel.info;
    }
  }
}

/// 实例代理门面：封装 Rust InstanceHandle，向业务层提供语义化调用。
class RustModuleInstance {
  RustModuleInstance._(this._moduleName, this._handle);

  final String _moduleName;
  final dynamic _handle; // InstanceHandle（FRB 生成类型）

  /// 实例句柄的字符串形式（信封 instance 字段；callModule 路由用）
  /// FRB 生成的 instanceId() 是异步方法，返回 Future<String>
  Future<String> get instanceId async =>
      instanceIdCache ??= await _handle.instanceId();
  String? instanceIdCache;

  /// 按**标准上下文**创建实例（宿主分配 data_dir/cache_dir，并带上 abi）。
  ///
  /// 约定见 `ModuleContext` / `rust/gstore_contract/src/context.rs`：
  /// 复用既有 `create(config)` 字节流，**零 ABI 变更**。新模块一律走这里。
  static Future<RustModuleInstance> createWithContext(
    String moduleName,
    ModuleHandle module, {
    String? dbPath,
  }) async {
    final ctx = await ModuleContext.forModule(moduleName, dbPath: dbPath);
    return create(moduleName, module, config: ctx.encode());
  }

  /// 创建实例（模块实现 create()）
  static Future<RustModuleInstance> create(
    String moduleName,
    ModuleHandle module, {
    Uint8List? config,
  }) async {
    final cfg = config ?? Uint8List(0);
    final handle = await module.createInstance(config: cfg);
    return RustModuleInstance._(moduleName, handle);
  }

  /// 实例方法调用 —— 统一信封入口（proto 编解码 + 异常模型）。
  /// 失败抛 [GStoreException] 分层异常。
  Future<Uint8List> callModule(String method,
      [Uint8List? payload]) async {
    return RustModuleManager.instance.callModule(
      _moduleName,
      await instanceId,
      method,
      payload ?? Uint8List(0),
    );
  }

  /// 显式释放实例（幂等）
  Future<void> dispose() => _handle.dispose();

  String get moduleName => _moduleName;
}
