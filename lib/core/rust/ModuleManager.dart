import 'dart:async' show unawaited;
import 'dart:typed_data';

import 'package:gstore/core/logger/LogManager.dart';
import 'package:gstore/core/rust/RustBridge.dart';
import 'package:gstore/core/rust/contract/GStoreException.dart';
import 'package:gstore/core/rust/generated/bridge.dart'
    show EventBridge, LogBridge, ModuleHandle;
import 'package:gstore/core/rust/generated/contract/envelope.pb.dart';
import 'package:gstore/core/rust/generated/event_bridge.dart'
    show ModuleEvent;
import 'package:gstore/core/rust/generated/log_bridge.dart' show LogMessage;

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
  static int _requestCounter = 0;
  static ModuleEventHandler? _moduleEventHandler;

  /// 注册模块事件处理器（业务层订阅模块推送的事件，如下载进度）
  void setModuleEventHandler(ModuleEventHandler handler) {
    _moduleEventHandler = handler;
  }

  /// 确保 bridge 初始化 + 日志订阅（幂等，可多次调用）
  Future<void> ensureReady() async {
    await RustBridge.ensureInitialized();
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
    Uint8List payload,
  ) async {
    await ensureReady();
    final requestId = 'req_${DateTime.now().microsecondsSinceEpoch}_${_requestCounter++}';
    final request = EnvelopeRequest(
      protocolVersion: 1,
      module: module,
      instance: instance ?? '',
      method: method,
      requestId: requestId,
      payload: payload,
    );

    final handle = await loadModule(module);
    final respBytes =
        await handle.callEnvelope(requestBytes: request.writeToBuffer());
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
      requestId: requestId,
    );
    appLog.warning(
        '[CallModule] $module.$method -> ${exception.status.name} $requestId: ${exception.errorCode} ${exception.message}');
    throw exception;
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

  /// 模块是否已加载（查询 Rust 侧注册表）
  Future<bool> isLoaded(String name) async {
    await ensureReady();
    final handle = _handles[name];
    if (handle == null) return false;
    return handle.isLoaded();
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
      // 挂载成功即入句柄缓存（模块名由宿主侧在挂载时确认，Dart 侧按路径首次加载）
      _handles.putIfAbsent(soPath, () => handle);
      return handle;
    } catch (e) {
      appLog.error('RustModuleManager: mountFromSo($soPath) 失败 - $e');
      return null;
    }
  }

  /// 订阅 Rust 日志流到 LogManager（Rust 日志可在日志查看器中查看）
  Future<void> _subscribeLogs() async {
    final bridge = await LogBridge.newInstance();
    bridge.logsStream().listen(_handleLogMessage);
  }

  /// 订阅模块事件流（模块经 emit_event 推送的事件，转发给注册的处理器共消费）
  Future<void> _subscribeEvents() async {
    final bridge = await EventBridge.newInstance();
    bridge.eventsStream().listen((event) {
      _moduleEventHandler?.call(event);
    });
  }

  void _handleLogMessage(LogMessage msg) {
    final level = _mapLevel(msg.level);
    final message =
        msg.module.isEmpty ? msg.message : '[${msg.module}] ${msg.message}';
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
