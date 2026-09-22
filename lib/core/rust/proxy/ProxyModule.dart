/// Proxy 模块 Dart 门面（`gstore_mod_proxy`）。
///
/// 纯展示 / 触发层：本文件只做两类翻译，**不含**任何解析、网络或路由逻辑
/// （全部在 Rust 侧，见 `rust/gstore_mod_proxy/API.md`）：
/// 1. 信封调用 → JSON 解码 → 类型化模型（[ping] / [version]）；
/// 2. 模块事件流 → 类型化事件（[ProxyEvent] 子类）。
///
/// 模块为**按需下载**（`API.md` §6：不随 APK 打包），故门面经
/// [ModuleBootstrap.run] 走统一自举门：首次使用时确保安装；模块不可安装 /
/// 未安装时抛出结构化的 [ProxyModuleUnavailableException]（不崩溃、不是裸错误）。
///
/// 底层经 [ProxyModuleGateway] 隔离，测试可注入假网关，**无需原生模块**。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:gstore/core/logger/LogManager.dart';
import 'package:gstore/core/rust/ModuleBootstrap.dart';
import 'package:gstore/core/rust/ModuleManager.dart';
import 'package:gstore/core/rust/contract/GStoreException.dart';
import 'package:gstore/core/rust/proxy/ProxyContract.dart';

// ==================== 枚举 ====================

/// 引擎连接状态（`proxy.state.state`）。
enum ProxyConnState {
  stopped('stopped'),
  starting('starting'),
  running('running'),
  stopping('stopping'),
  unknown('unknown');

  const ProxyConnState(this.wire);

  /// 模块 JSON 中的字面值。
  final String wire;

  /// 宽容解码：未知值归为 [unknown]（绝不抛错）。
  static ProxyConnState fromWire(Object? value) {
    final s = value?.toString();
    for (final state in values) {
      if (state.wire == s) return state;
    }
    return ProxyConnState.unknown;
  }
}

/// 运行模式（`proxy.mode.mode` / `core.get_mode.mode`）。
enum ProxyMode {
  off('off'),
  vpn('vpn'),
  lanProxy('lanProxy'),
  unknown('unknown');

  const ProxyMode(this.wire);

  /// 模块 JSON 中的字面值。
  final String wire;

  /// 宽容解码：未知值归为 [unknown]（绝不抛错）。
  static ProxyMode fromWire(Object? value) {
    final s = value?.toString();
    for (final mode in values) {
      if (mode.wire == s) return mode;
    }
    return ProxyMode.unknown;
  }
}

/// 路由模式（`routing.get_mode.mode` / `routing.set_mode.mode`）。
///
/// 与 [ProxyMode]（运行模式 VPN/局域网/关闭）**区分**：这里表达流量如何分流。
enum ProxyRoutingMode {
  direct('direct'),
  rule('rule'),
  global('global'),
  unknown('unknown');

  const ProxyRoutingMode(this.wire);

  /// 模块 JSON 中的字面值。
  final String wire;

  /// 宽容解码：未知值归为 [unknown]（绝不抛错）。
  static ProxyRoutingMode fromWire(Object? value) {
    final s = value?.toString();
    for (final mode in values) {
      if (mode.wire == s) return mode;
    }
    return ProxyRoutingMode.unknown;
  }
}

/// 订阅刷新进度阶段（`proxy.subscription.progress.phase`）。
enum ProxySubscriptionPhase {
  fetch('fetch'),
  persist('persist'),
  unknown('unknown');

  const ProxySubscriptionPhase(this.wire);

  final String wire;

  static ProxySubscriptionPhase fromWire(Object? value) {
    final s = value?.toString();
    for (final phase in values) {
      if (phase.wire == s) return phase;
    }
    return ProxySubscriptionPhase.unknown;
  }
}

/// 订阅刷新进度状态（`proxy.subscription.progress.state`）。
enum ProxySubscriptionProgressState {
  started('started'),
  succeeded('succeeded'),
  failed('failed'),
  unknown('unknown');

  const ProxySubscriptionProgressState(this.wire);

  final String wire;

  static ProxySubscriptionProgressState fromWire(Object? value) {
    final s = value?.toString();
    for (final state in values) {
      if (state.wire == s) return state;
    }
    return ProxySubscriptionProgressState.unknown;
  }
}

// ==================== 异常 ====================

/// 代理模块调用失败（信封错误或响应非法）。
class ProxyModuleException implements Exception {
  const ProxyModuleException({
    required this.code,
    required this.message,
    this.status,
  });

  /// 错误码（如 `METHOD_NOT_FOUND` / `PROXY_*`）。
  final String code;

  /// 人类可读消息。
  final String message;

  /// 信封 HTTP 状态码（非信封路径时为 `null`）。
  final int? status;

  @override
  String toString() =>
      'ProxyModuleException($code${status == null ? '' : '/$status'}): $message';
}

/// 代理模块不可用（未安装 / 无法安装 / 用户取消确认）。
///
/// 对应 `API.md` §6 的「按需下载」：模块缺失是**预期状态**而非崩溃。
class ProxyModuleUnavailableException extends ProxyModuleException {
  ProxyModuleUnavailableException({this.declined = false, this.cause})
      : super(
          code: declined ? 'PROXY_MODULE_DECLINED' : 'PROXY_MODULE_UNINSTALLED',
          message: declined ? '代理模块安装被取消' : '代理模块未安装',
        );

  /// 用户是否在安装确认弹层中拒绝。
  final bool declined;

  /// 底层错误（诊断用，可为 `null`）。
  final Object? cause;
}

// ==================== 原始事件 / 网关 ====================

/// 原始代理事件（模块 → 宿主）：事件名 + JSON 字节载荷。
class ProxyRawEvent {
  const ProxyRawEvent({required this.eventType, required this.data});

  /// 事件名（如 `proxy.state`）。
  final String eventType;

  /// JSON 载荷字节。
  final Uint8List data;
}

/// 门面底层网关：把「模块调用」与「事件流」从 [ProxyModule] 隔离，
/// 使单元 / 组件测试可注入假实现，**无需原生模块**。
abstract class ProxyModuleGateway {
  /// 执行一次信封调用，返回解包后的 JSON 载荷字节（`{ok:true,data:{...}}`）。
  Future<Uint8List> call(String method, [Uint8List? payload]);

  /// 代理模块事件流（已按 `proxy.` 前缀过滤）。
  Stream<ProxyRawEvent> get events;
}

/// 生产网关：经 [ModuleBootstrap] 自举 + [RustModuleManager] 事件总线。
class _RustProxyGateway implements ProxyModuleGateway {
  @override
  Future<Uint8List> call(String method, [Uint8List? payload]) {
    return ModuleBootstrap.instance.run<Uint8List>(
      ProxyModule.moduleName,
      (instance) => instance.callModule(method, payload),
      maxAttempts: 1,
    );
  }

  @override
  Stream<ProxyRawEvent> get events =>
      RustModuleManager.instance.moduleEvents
          .where((event) =>
              event.eventType.startsWith('${ProxyModule.moduleName}.'))
          .map((event) =>
              ProxyRawEvent(eventType: event.eventType, data: event.data));
}

// ==================== 展示层契约 ====================

/// 展示层依赖的只读门面契约（便于组件测试注入假实现）。
abstract class ProxyFacade {
  /// 心跳 / 当前状态快照。
  Future<ProxyPingResult> ping();

  /// 模块构建与能力信息。
  Future<ProxyVersionInfo> version();

  /// 类型化代理事件流。
  Stream<ProxyEvent> get events;
}

// ==================== 门面 ====================

/// 代理模块门面（单例 [instance]，测试可经构造函数注入 [ProxyModuleGateway]）。
class ProxyModule implements ProxyFacade {
  ProxyModule({ProxyModuleGateway? gateway})
      : _gateway = gateway ?? _RustProxyGateway();

  /// 模块名（与 Rust 注册名一致，`API.md` §1）。
  static const String moduleName = 'proxy';

  /// 模块要求的最低宿主 ABI（`API.md` 头部：`min_host_abi = 3`）。
  static const int minHostAbi = 3;

  static ProxyModule? _instance;

  /// 生产单例入口。
  static ProxyModule get instance => _instance ??= ProxyModule();

  final ProxyModuleGateway _gateway;

  StreamController<ProxyEvent>? _eventController;
  StreamSubscription<ProxyRawEvent>? _eventPump;

  @override
  Future<ProxyPingResult> ping() async =>
      ProxyPingResult.fromJson(await _call('ping'));

  @override
  Future<ProxyVersionInfo> version() async =>
      ProxyVersionInfo.fromJson(await _call('version'));

  /// 类型化事件广播流。
  ///
  /// 首次访问时**同步**挂载对模块事件总线的单一订阅（`listen` 同步附着），
  /// 因此后续 `listen` / `first` 不会错过紧随其后的 `add`（广播流不缓冲）。
  @override
  Stream<ProxyEvent> get events {
    final controller = _eventController ??=
        StreamController<ProxyEvent>.broadcast(sync: true);
    _eventPump ??= _gateway.events.listen((raw) {
      final event = ProxyEvent.decode(raw);
      if (event != null && !controller.isClosed) {
        controller.add(event);
      }
    });
    return controller.stream;
  }

  /// 通用类型化调用：信封 → `data` → [decode]。
  ///
  /// 展示层所有方法都经此入口，方法名与响应模型见 [ProxyMethods] /
  /// [proxyResponseDecoders]（`API.md` 的 Dart 镜像）。
  Future<T> invoke<T>(
    String method,
    T Function(Map<String, dynamic> json) decode, {
    Map<String, dynamic>? payload,
  }) async {
    final data = await _call(
      method,
      payload == null ? null : encodeProxyPayload(payload),
    );
    return decode(data);
  }

  // ---- core.* ----

  /// `tun.set_fd`：把宿主 TUN fd 交给模块。
  Future<TunSetFdResult> tunSetFd(int fd) => invoke(
        ProxyMethods.tunSetFd,
        TunSetFdResult.fromJson,
        payload: TunSetFdRequest(fd).toJson(),
      );

  /// `core.start`：按生成配置启动引擎。
  Future<ProxyCoreStatus> coreStart(CoreStartRequest request) => invoke(
        ProxyMethods.coreStart,
        ProxyCoreStatus.fromJson,
        payload: request.toJson(),
      );

  /// `core.stop`：停止引擎并释放 TUN。
  Future<CoreStopResult> coreStop() =>
      invoke(ProxyMethods.coreStop, CoreStopResult.fromJson);

  /// `core.restart`：重建 tunnel 并重新发布配置。
  Future<ProxyCoreStatus> coreRestart(CoreStartRequest request) => invoke(
        ProxyMethods.coreRestart,
        ProxyCoreStatus.fromJson,
        payload: request.toJson(),
      );

  /// `core.get_mode`：当前模式/状态快照。
  Future<CoreModeResult> coreGetMode() =>
      invoke(ProxyMethods.coreGetMode, CoreModeResult.fromJson);

  /// `core.set_mode`：切换运行模式。
  Future<CoreSetModeResult> coreSetMode(String mode) => invoke(
        ProxyMethods.coreSetMode,
        CoreSetModeResult.fromJson,
        payload: CoreSetModeRequest(mode).toJson(),
      );

  /// `routing.get_mode`：当前路由模式（直连/规则/全局）+ 引擎是否运行。
  Future<RoutingModeResult> routingGetMode() =>
      invoke(ProxyMethods.routingGetMode, RoutingModeResult.fromJson);

  /// `routing.set_mode`：切换路由模式。引擎未运行时返回 `applied:false`。
  Future<RoutingModeSetResult> routingSetMode(String mode) => invoke(
        ProxyMethods.routingSetMode,
        RoutingModeSetResult.fromJson,
        payload: RoutingSetModeRequest(mode).toJson(),
      );

  // ---- dns.* ----

  /// `dns.get`：有效 DNS 配置 + 统计 + 近期映射/查询。
  Future<DnsSnapshot> dnsGet() =>
      invoke(ProxyMethods.dnsGet, DnsSnapshot.fromJson);

  /// `dns.set`：合并并安装部分 DNS 配置。
  Future<DnsSetResult> dnsSet(DnsConfig config) => invoke(
        ProxyMethods.dnsSet,
        DnsSetResult.fromJson,
        payload: config.toJson(),
      );

  /// `dns.clear_cache`：清空缓存与 fake-IP 分配。
  Future<DnsClearResult> dnsClearCache() =>
      invoke(ProxyMethods.dnsClearCache, DnsClearResult.fromJson);

  /// `dns.flush_cache`：`dns.clear_cache` 的别名。
  Future<DnsClearResult> dnsFlushCache() =>
      invoke(ProxyMethods.dnsFlushCache, DnsClearResult.fromJson);

  // ---- log.* ----

  /// `log.get`：按游标分页读取日志环。
  Future<LogPage> logGet([LogGetRequest request = const LogGetRequest()]) =>
      invoke(
        ProxyMethods.logGet,
        LogPage.fromJson,
        payload: request.toJson(),
      );

  /// `log.set_level`：设置日志保留级别。
  Future<LogSetLevelResult> logSetLevel(String level) => invoke(
        ProxyMethods.logSetLevel,
        LogSetLevelResult.fromJson,
        payload: LogSetLevelRequest(level).toJson(),
      );

  /// `log.clear`：清空日志环（游标继续前进）。
  Future<OkResult> logClear() =>
      invoke(ProxyMethods.logClear, OkResult.fromJson);

  // ---- rules.* ----

  /// `rules.get`：只读规则快照。
  Future<RulesSnapshot> rulesGet() =>
      invoke(ProxyMethods.rulesGet, RulesSnapshot.fromJson);

  /// `rules.reload`：解析并发布规则集。
  Future<RulesSnapshot> rulesReload(RulesReloadRequest request) => invoke(
        ProxyMethods.rulesReload,
        RulesSnapshot.fromJson,
        payload: request.toJson(),
      );

  // ---- config.* ----

  /// `config.generate`：渲染受控 Clash 模板（不触碰运行中引擎）。
  Future<GeneratedConfig> configGenerate(GenerateRequest request) => invoke(
        ProxyMethods.configGenerate,
        GeneratedConfig.fromJson,
        payload: request.toJson(),
      );

  /// `config.apply`：热应用配置到运行中引擎。
  Future<GeneratedConfig> configApply(GenerateRequest request) => invoke(
        ProxyMethods.configApply,
        GeneratedConfig.fromJson,
        payload: request.toJson(),
      );

  // ---- profile.* ----

  /// `profile.export_clash`：导出单个存储 profile 的生成配置。
  Future<GeneratedConfig> profileExportClash(ProfileExportRequest request) =>
      invoke(
        ProxyMethods.profileExportClash,
        GeneratedConfig.fromJson,
        payload: request.toJson(),
      );

  /// `profile.import_url`：经 protect 感知传输抓取并解析订阅。
  Future<ImportedProfile> profileImportUrl({
    required String url,
    String? name,
    String? userAgent,
  }) =>
      invoke(
        ProxyMethods.profileImportUrl,
        ImportedProfile.fromJson,
        payload: <String, dynamic>{
          'url': url,
          if (name != null) 'name': name,
          if (userAgent != null) 'userAgent': userAgent,
        },
      );

  /// `profile.import_text`：解析已抓取的订阅正文。
  Future<ImportedProfile> profileImportText({
    required String text,
    String? name,
    String? contentType,
  }) =>
      invoke(
        ProxyMethods.profileImportText,
        ImportedProfile.fromJson,
        payload: <String, dynamic>{
          'text': text,
          if (name != null) 'name': name,
          if (contentType != null) 'contentType': contentType,
        },
      );

  /// `profile.import_link`：解析单条分享链接。
  Future<ImportedProfile> profileImportLink({
    required String link,
    String? name,
  }) =>
      invoke(
        ProxyMethods.profileImportLink,
        ImportedProfile.fromJson,
        payload: <String, dynamic>{
          'link': link,
          if (name != null) 'name': name,
        },
      );

  /// `profile.list`：稳定排序的存储摘要。
  Future<ProfileList> profileList() =>
      invoke(ProxyMethods.profileList, ProfileList.fromJson);

  /// `profile.get`：按 id 读取一个存储 profile。
  Future<StoredProfile> profileGet(String id) => invoke(
        ProxyMethods.profileGet,
        StoredProfile.fromJson,
        payload: ProfileIdRequest(id).toJson(),
      );

  /// `profile.create`：持久化一个规范 profile。
  Future<StoredProfile> profileCreate(ProfileCreateRequest request) => invoke(
        ProxyMethods.profileCreate,
        StoredProfile.fromJson,
        payload: request.toJson(),
      );

  /// `profile.update`：更新内容/元数据/刷新标记。
  Future<StoredProfile> profileUpdate(Map<String, dynamic> payload) => invoke(
        ProxyMethods.profileUpdate,
        StoredProfile.fromJson,
        payload: payload,
      );

  /// `profile.delete`：删除 profile 并发出 removed 事件。
  Future<ProfileDeleteResult> profileDelete(String id) => invoke(
        ProxyMethods.profileDelete,
        ProfileDeleteResult.fromJson,
        payload: ProfileIdRequest(id).toJson(),
      );

  /// `profile.refresh`：单 profile 刷新（失败保留旧内容）。
  Future<RefreshResult> profileRefresh(String id, {bool force = false}) =>
      invoke(
        ProxyMethods.profileRefresh,
        RefreshResult.fromJson,
        payload: ProfileIdRequest(id, force: force).toJson(),
      );

  /// `profile.refresh_all`：有界批量刷新。
  Future<RefreshAllResult> profileRefreshAll({
    bool force = false,
    int? limit,
  }) =>
      invoke(
        ProxyMethods.profileRefreshAll,
        RefreshAllResult.fromJson,
        payload: ProfileRefreshAllRequest(force: force, limit: limit).toJson(),
      );

  /// `profile.set_schedule`：设置/清除自动刷新间隔（0 = 清除）。
  Future<StoredProfile> profileSetSchedule(String id, int intervalMs) => invoke(
        ProxyMethods.profileSetSchedule,
        StoredProfile.fromJson,
        payload:
            ProfileSetScheduleRequest(id: id, intervalMs: intervalMs).toJson(),
      );

  // ---- node.* ----

  /// `node.select`：把用户选择应用到 selector/url-test/fallback 组。
  Future<NodeSelectResult> nodeSelect(String group, String node) => invoke(
        ProxyMethods.nodeSelect,
        NodeSelectResult.fromJson,
        payload: NodeSelectRequest(group: group, node: node).toJson(),
      );

  /// `node.delay_test`：逐节点 HTTP 探测（不可达是逐项结果，不是调用错误）。
  Future<DelayTestResult> nodeDelayTest(NodeDelayTestRequest request) => invoke(
        ProxyMethods.nodeDelayTest,
        DelayTestResult.fromJson,
        payload: request.toJson(),
      );

  /// `node.list`：只读列出各代理组的实时选中（`now`）与当前路由分组。
  /// 引擎未运行时返回 `engineRunning:false`，绝不抛错。
  Future<NodeListResult> nodeList() =>
      invoke(ProxyMethods.nodeList, NodeListResult.fromJson);

  // ---- conn.* ----

  /// `conn.list`：分页/可过滤的活动连接。
  Future<ConnPage> connList(ConnListRequest request) => invoke(
        ProxyMethods.connList,
        ConnPage.fromJson,
        payload: request.toJson(),
      );

  /// `conn.close`：幂等关闭一个连接。
  Future<ConnCloseResult> connClose(String id) => invoke(
        ProxyMethods.connClose,
        ConnCloseResult.fromJson,
        payload: ConnCloseRequest(id).toJson(),
      );

  /// `conn.close_all`：关闭全部连接。
  Future<ConnCloseAllResult> connCloseAll() =>
      invoke(ProxyMethods.connCloseAll, ConnCloseAllResult.fromJson);

  // ---- stats.* ----

  /// `stats.domain.get`：按域名聚合统计（主路径，拉取式）。
  Future<DomainPage> statsDomainGet(StatsDomainGetRequest request) => invoke(
        ProxyMethods.statsDomainGet,
        DomainPage.fromJson,
        payload: request.toJson(),
      );

  /// `stats.domain.reset`：清空聚合与持久化行。
  Future<StatsResetResult> statsDomainReset() =>
      invoke(ProxyMethods.statsDomainReset, StatsResetResult.fromJson);

  /// `stats.traffic.get`：聚合流量快照。
  Future<TrafficSnapshot> statsTrafficGet({int? topDomains}) => invoke(
        ProxyMethods.statsTrafficGet,
        TrafficSnapshot.fromJson,
        payload: StatsTrafficGetRequest(topDomains: topDomains).toJson(),
      );

  /// `stats.get`：`stats.domain.get` 的别名。
  Future<DomainPage> statsGet(StatsDomainGetRequest request) => invoke(
        ProxyMethods.statsGet,
        DomainPage.fromJson,
        payload: request.toJson(),
      );

  /// `stats.reset`：`stats.domain.reset` 的别名。
  Future<StatsResetResult> statsReset() =>
      invoke(ProxyMethods.statsReset, StatsResetResult.fromJson);

  // ---- diagnostics.* ----

  /// `diagnostics.clash_api.start`：启用 meow 回环控制器（默认 OFF，仅诊断）。
  Future<ClashApiStatus> clashApiStart({int port = 0}) => invoke(
        ProxyMethods.clashApiStart,
        ClashApiStatus.fromJson,
        payload: ClashApiStartRequest(port: port).toJson(),
      );

  /// `diagnostics.clash_api.stop`：停止回环控制器。
  Future<ClashApiStopResult> clashApiStop() =>
      invoke(ProxyMethods.clashApiStop, ClashApiStopResult.fromJson);

  /// `diagnostics.clash_api.status`：控制器状态（**不含 secret**）。
  Future<ClashApiStatus> clashApiStatus() =>
      invoke(ProxyMethods.clashApiStatus, ClashApiStatus.fromJson);

  /// 调用信封 → 校验 `{ok:true,data:{...}}` → 返回 `data`。
  ///
  /// 错误分层：模块不可用 → [ProxyModuleUnavailableException]；
  /// 其余信封 / 业务错误 → [ProxyModuleException]。
  Future<Map<String, dynamic>> _call(
    String method, [
    Uint8List? payload,
  ]) async {
    try {
      final bytes = await _gateway.call(method, payload);
      final Object? decoded;
      try {
        decoded = jsonDecode(utf8.decode(bytes, allowMalformed: true));
      } catch (error) {
        throw const ProxyModuleException(
          code: 'PAYLOAD_DECODE_FAILED',
          message: '代理模块响应不是合法 JSON',
          status: 400,
        );
      }
      if (decoded is! Map<String, dynamic>) {
        throw const ProxyModuleException(
          code: 'PAYLOAD_DECODE_FAILED',
          message: '代理模块响应不是 JSON 对象',
          status: 400,
        );
      }
      if (decoded['ok'] != true) {
        throw ProxyModuleException(
          code: decoded['code']?.toString() ?? 'BAD_REQUEST',
          message: decoded['message']?.toString() ?? '代理模块返回错误',
          status: _asIntOrNull(decoded['status']) ?? 400,
        );
      }
      final data = decoded['data'];
      return data is Map<String, dynamic> ? data : const <String, dynamic>{};
    } on ProxyModuleException {
      rethrow;
    } on ModuleInstallFailedException catch (error) {
      throw ProxyModuleUnavailableException(cause: error);
    } on ModuleInstallDeclinedException catch (error) {
      throw ProxyModuleUnavailableException(declined: true, cause: error);
    } on GStoreException catch (error) {
      throw ProxyModuleException(
        code: error.errorCode,
        message: error.message,
        status: error.status.value,
      );
    } catch (error) {
      // 宿主 ModuleHandle.load 的失败值是裸 String；未安装 / 无法加载统一降级为
      // 结构化的「模块未安装」状态，绝不向上抛裸错误。
      appLog.warning('ProxyModule: $method 调用失败（按模块不可用处理）- $error');
      throw ProxyModuleUnavailableException(cause: error);
    }
  }
}

// ==================== 结果模型 ====================

/// `ping` 响应（`API.md` §2.1）。
class ProxyPingResult {
  const ProxyPingResult({
    required this.pong,
    required this.module,
    required this.moduleVersion,
    required this.apiVersion,
    required this.minHostAbi,
    required this.hostAbi,
    this.instanceId,
    this.state,
    this.mode,
    this.protectFdPresent,
  });

  factory ProxyPingResult.fromJson(Map<String, dynamic> json) => ProxyPingResult(
        pong: json['pong'] == true,
        module: json['module']?.toString() ?? ProxyModule.moduleName,
        moduleVersion: json['moduleVersion']?.toString() ?? '',
        apiVersion: _asInt(json['apiVersion']),
        minHostAbi: _asInt(json['minHostAbi']),
        hostAbi: _asInt(json['hostAbi']),
        instanceId: _asIntOrNull(json['instanceId']),
        state: json['state'] == null
            ? null
            : ProxyConnState.fromWire(json['state']),
        mode: json['mode'] == null ? null : ProxyMode.fromWire(json['mode']),
        protectFdPresent: json['protectFdPresent'] is bool
            ? json['protectFdPresent'] as bool
            : null,
      );

  /// 模块存活。
  final bool pong;

  /// 模块名（恒为 `proxy`）。
  final String module;

  /// 模块版本。
  final String moduleVersion;

  /// 模块 API 版本。
  final int apiVersion;

  /// 模块要求的最低宿主 ABI。
  final int minHostAbi;

  /// 宿主实际 ABI。
  final int hostAbi;

  /// 实例 id（仅带实例调用时出现）。
  final int? instanceId;

  /// 引擎状态（仅带实例调用时出现）。
  final ProxyConnState? state;

  /// 当前模式（仅带实例调用时出现）。
  final ProxyMode? mode;

  /// 宿主是否提供了 `protect_fd`（仅带实例调用时出现）。
  final bool? protectFdPresent;

  /// 宿主 ABI 是否满足模块要求。
  bool get hostCompatible => minHostAbi <= hostAbi;
}

/// `version` 响应（`API.md` §2.2）。
class ProxyVersionInfo {
  const ProxyVersionInfo({
    required this.module,
    required this.moduleVersion,
    required this.apiVersion,
    required this.minHostAbi,
    required this.hostAbi,
    required this.meowRev,
    required this.targetArch,
  });

  factory ProxyVersionInfo.fromJson(Map<String, dynamic> json) =>
      ProxyVersionInfo(
        module: json['module']?.toString() ?? ProxyModule.moduleName,
        moduleVersion: json['moduleVersion']?.toString() ?? '',
        apiVersion: _asInt(json['apiVersion']),
        minHostAbi: _asInt(json['minHostAbi']),
        hostAbi: _asInt(json['hostAbi']),
        meowRev: json['meowRev']?.toString() ?? '',
        targetArch: json['targetArch']?.toString() ?? '',
      );

  /// 模块名（恒为 `proxy`）。
  final String module;

  /// 模块版本。
  final String moduleVersion;

  /// 模块 API 版本。
  final int apiVersion;

  /// 模块要求的最低宿主 ABI。
  final int minHostAbi;

  /// 宿主实际 ABI。
  final int hostAbi;

  /// meow 内核 pin 的 git rev。
  final String meowRev;

  /// 目标架构（如 `aarch64`）。
  final String targetArch;

  /// 宿主 ABI 是否满足模块要求。
  bool get hostCompatible => minHostAbi <= hostAbi;
}

/// 流量计数（`Profile.traffic` / `proxy.subscription.updated.traffic`）。
class ProxyTraffic {
  const ProxyTraffic({
    this.uploadBytes = 0,
    this.downloadBytes = 0,
    this.totalBytes = 0,
    this.usedBytes = 0,
  });

  factory ProxyTraffic.fromJson(Object? json) {
    if (json is! Map) return const ProxyTraffic();
    return ProxyTraffic(
      uploadBytes: _asInt(json['uploadBytes']),
      downloadBytes: _asInt(json['downloadBytes']),
      totalBytes: _asInt(json['totalBytes']),
      usedBytes: _asInt(json['usedBytes']),
    );
  }

  final int uploadBytes;
  final int downloadBytes;
  final int totalBytes;
  final int usedBytes;
}

/// `proxy.state.error` 结构（`API.md` §3）。
class ProxyStateError {
  const ProxyStateError({required this.code, required this.message});

  /// 解析错误对象；非对象返回 `null`。
  static ProxyStateError? fromJson(Object? json) {
    if (json is! Map) return null;
    return ProxyStateError(
      code: json['code']?.toString() ?? '',
      message: json['message']?.toString() ?? '',
    );
  }

  final String code;
  final String message;
}

// ==================== 事件模型 ====================

/// 类型化代理事件基类（`API.md` §3）。
sealed class ProxyEvent {
  const ProxyEvent();

  /// 事件名（如 `proxy.state`）。
  String get eventType;

  /// 解析原始事件；未知 / 非 JSON 载荷返回 `null`（门面静默忽略，绝不抛错）。
  static ProxyEvent? decode(ProxyRawEvent raw) {
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(raw.data, allowMalformed: true));
    } catch (error) {
      appLog.debug('ProxyModule: 事件 ${raw.eventType} 载荷非 JSON - $error');
      return null;
    }
    final data = decoded is Map<String, dynamic>
        ? decoded
        : const <String, dynamic>{};

    switch (raw.eventType) {
      case 'proxy.state':
        return ProxyStateEvent(
          state: ProxyConnState.fromWire(data['state']),
          mode: ProxyMode.fromWire(data['mode']),
          reason: data['reason']?.toString(),
          error: ProxyStateError.fromJson(data['error']),
        );
      case 'proxy.mode':
        return ProxyModeEvent(
          mode: ProxyMode.fromWire(data['mode']),
          previous: ProxyMode.fromWire(data['previous']),
        );
      case 'proxy.node.delay':
        return ProxyNodeDelayEvent(
          group: data['group']?.toString() ?? '',
          node: data['node']?.toString() ?? '',
          delayMs: _asInt(data['delayMs']),
          error: data['error']?.toString(),
        );
      case 'proxy.stats':
        return ProxyStatsEvent(
          uploadBytes: _asInt(data['uploadBytes']),
          downloadBytes: _asInt(data['downloadBytes']),
          activeConns: _asInt(data['activeConns']),
          upBps: _asInt(data['upBps']),
          downBps: _asInt(data['downBps']),
          domainCount: _asInt(data['domainCount']),
          capacity: _asInt(data['capacity']),
          topDomains: (data['topDomains'] is List)
              ? (data['topDomains'] as List)
                  .whereType<Map>()
                  .map((e) => DomainStat.fromJson(e.cast<String, dynamic>()))
                  .toList()
              : const <DomainStat>[],
        );
      case 'proxy.subscription.updated':
        return ProxySubscriptionUpdatedEvent(
          profileId: data['profileId']?.toString() ?? '',
          nodeCount: _asInt(data['nodeCount']),
          traffic: ProxyTraffic.fromJson(data['traffic']),
          expireAtMs: _asInt(data['expireAtMs']),
          lastUpdatedAtMs: _asInt(data['lastUpdatedAtMs']),
          intervalMs: _asInt(data['intervalMs']),
          nextRefreshAtMs: _asInt(data['nextRefreshAtMs']),
        );
      case 'proxy.subscription.progress':
        return ProxySubscriptionProgressEvent(
          profileId: data['profileId']?.toString() ?? '',
          phase: ProxySubscriptionPhase.fromWire(data['phase']),
          state: ProxySubscriptionProgressState.fromWire(data['state']),
          attempts: _asInt(data['attempts']),
        );
      case 'proxy.subscription.failed':
        return ProxySubscriptionFailedEvent(
          profileId: data['profileId']?.toString() ?? '',
          attempts: _asInt(data['attempts']),
          consecutiveFailures: _asInt(data['consecutiveFailures']),
          lastAttemptMs: _asInt(data['lastAttemptMs']),
          nextRefreshAtMs: _asInt(data['nextRefreshAtMs']),
          error: ProxyStateError.fromJson(data['error']),
        );
      case 'proxy.subscription.added':
        return ProxySubscriptionAddedEvent(
          profileId: data['profileId']?.toString() ?? '',
          name: data['name']?.toString() ?? '',
        );
      case 'proxy.subscription.removed':
        return ProxySubscriptionRemovedEvent(
          profileId: data['profileId']?.toString() ?? '',
        );
      case 'proxy.conn':
        return ProxyConnEvent(
          action: data['action']?.toString() ?? '',
          id: data['id']?.toString() ?? '',
          domain: data['domain']?.toString(),
          outbound: data['outbound']?.toString(),
          uploadBytes: _asIntOrNull(data['uploadBytes']),
          downloadBytes: _asIntOrNull(data['downloadBytes']),
          closed: _asIntOrNull(data['closed']),
        );
      case 'proxy.dns':
        return ProxyDnsEvent(record: DnsQueryRecord.fromJson(data));
      case 'proxy.tun.released':
        return ProxyTunReleasedEvent(fd: _asInt(data['fd']));
      case 'proxy.config.applied':
        return ProxyConfigAppliedEvent(
          profileId: data['profileId']?.toString() ?? '',
          hash: data['hash']?.toString() ?? '',
          template: data['template']?.toString() ?? '',
        );
      default:
        return null;
    }
  }
}

/// `proxy.state`：引擎状态变更。
final class ProxyStateEvent extends ProxyEvent {
  const ProxyStateEvent({
    required this.state,
    required this.mode,
    this.reason,
    this.error,
  });

  final ProxyConnState state;
  final ProxyMode mode;
  final String? reason;
  final ProxyStateError? error;

  @override
  String get eventType => 'proxy.state';

  /// 是否已连接运行。
  bool get isRunning => state == ProxyConnState.running;

  /// 是否携带错误。
  bool get hasError => error != null;
}

/// `proxy.mode`：运行模式切换。
final class ProxyModeEvent extends ProxyEvent {
  const ProxyModeEvent({required this.mode, required this.previous});

  final ProxyMode mode;
  final ProxyMode previous;

  @override
  String get eventType => 'proxy.mode';
}

/// `proxy.node.delay`：单个节点延迟测试结果。
final class ProxyNodeDelayEvent extends ProxyEvent {
  const ProxyNodeDelayEvent({
    required this.group,
    required this.node,
    required this.delayMs,
    this.error,
  });

  final String group;
  final String node;
  final int delayMs;
  final String? error;

  @override
  String get eventType => 'proxy.node.delay';
}

/// `proxy.stats`：流量统计（节流推送，>= 1s 一次）。
final class ProxyStatsEvent extends ProxyEvent {
  const ProxyStatsEvent({
    required this.uploadBytes,
    required this.downloadBytes,
    required this.activeConns,
    required this.upBps,
    required this.downBps,
    this.domainCount = 0,
    this.capacity = 0,
    this.topDomains = const <DomainStat>[],
  });

  final int uploadBytes;
  final int downloadBytes;
  final int activeConns;
  final int upBps;
  final int downBps;

  /// 已聚合的不同域名数量。
  final int domainCount;

  /// 域名聚合容量上限。
  final int capacity;

  /// 按总字节降序的 top 域名（推送时截断）。
  final List<DomainStat> topDomains;

  @override
  String get eventType => 'proxy.stats';
}

/// `proxy.subscription.updated`：订阅信息更新（含 userinfo 与调度元数据）。
final class ProxySubscriptionUpdatedEvent extends ProxyEvent {
  const ProxySubscriptionUpdatedEvent({
    required this.profileId,
    required this.nodeCount,
    required this.traffic,
    required this.expireAtMs,
    this.lastUpdatedAtMs = 0,
    this.intervalMs = 0,
    this.nextRefreshAtMs = 0,
  });

  final String profileId;
  final int nodeCount;
  final ProxyTraffic traffic;
  final int expireAtMs;

  /// 最近一次成功刷新时间（Unix ms；0 = 未知）。
  final int lastUpdatedAtMs;

  /// 自动更新间隔（ms；0 = 仅手动）。
  final int intervalMs;

  /// 下次可刷新的最早时间（Unix ms；0 = 未知）。
  final int nextRefreshAtMs;

  @override
  String get eventType => 'proxy.subscription.updated';
}

/// `proxy.subscription.progress`：刷新进度（started/succeeded/failed）。
final class ProxySubscriptionProgressEvent extends ProxyEvent {
  const ProxySubscriptionProgressEvent({
    required this.profileId,
    required this.phase,
    required this.state,
    required this.attempts,
  });

  final String profileId;
  final ProxySubscriptionPhase phase;
  final ProxySubscriptionProgressState state;
  final int attempts;

  @override
  String get eventType => 'proxy.subscription.progress';
}

/// `proxy.subscription.failed`：刷新失败（旧 profile 保留，进入有界退避）。
final class ProxySubscriptionFailedEvent extends ProxyEvent {
  const ProxySubscriptionFailedEvent({
    required this.profileId,
    required this.attempts,
    required this.consecutiveFailures,
    required this.lastAttemptMs,
    required this.nextRefreshAtMs,
    this.error,
  });

  final String profileId;
  final int attempts;
  final int consecutiveFailures;
  final int lastAttemptMs;
  final int nextRefreshAtMs;
  final ProxyStateError? error;

  @override
  String get eventType => 'proxy.subscription.failed';
}

/// `proxy.subscription.added`：订阅新增。
final class ProxySubscriptionAddedEvent extends ProxyEvent {
  const ProxySubscriptionAddedEvent({
    required this.profileId,
    required this.name,
  });

  final String profileId;
  final String name;

  @override
  String get eventType => 'proxy.subscription.added';
}

/// `proxy.subscription.removed`：订阅删除。
final class ProxySubscriptionRemovedEvent extends ProxyEvent {
  const ProxySubscriptionRemovedEvent({required this.profileId});

  final String profileId;

  @override
  String get eventType => 'proxy.subscription.removed';
}

/// `proxy.conn`：连接开闭事件。
final class ProxyConnEvent extends ProxyEvent {
  const ProxyConnEvent({
    required this.action,
    required this.id,
    this.domain,
    this.outbound,
    this.uploadBytes,
    this.downloadBytes,
    this.closed,
  });

  /// `close` 或 `close_all`。
  final String action;
  final String id;
  final String? domain;
  final String? outbound;
  final int? uploadBytes;
  final int? downloadBytes;

  /// 仅 `action:"close_all"` 携带：本次关闭的连接数。
  final int? closed;

  @override
  String get eventType => 'proxy.conn';
}

/// `proxy.dns`：TUN DNS 劫持应答的一条查询记录。
final class ProxyDnsEvent extends ProxyEvent {
  const ProxyDnsEvent({required this.record});

  final DnsQueryRecord record;

  @override
  String get eventType => 'proxy.dns';

  /// 是否成功应答。
  bool get ok => record.ok;

  /// 查询域名。
  String get domain => record.domain;
}

/// `proxy.tun.released`：TUN 读取循环已停止并 join，宿主可清缓存 fd。
///
/// 宿主内部事件；Dart 可忽略，但仍在此类型化以保证契约完整。
final class ProxyTunReleasedEvent extends ProxyEvent {
  const ProxyTunReleasedEvent({required this.fd});

  /// 已释放的宿主 TUN fd。
  final int fd;

  @override
  String get eventType => 'proxy.tun.released';
}

/// `proxy.config.applied`：`config.apply` 已在运行中引擎热应用新配置。
final class ProxyConfigAppliedEvent extends ProxyEvent {
  const ProxyConfigAppliedEvent({
    required this.profileId,
    required this.hash,
    required this.template,
  });

  final String profileId;
  final String hash;
  final String template;

  @override
  String get eventType => 'proxy.config.applied';
}

// ==================== JSON 工具 ====================

int _asInt(Object? value) => _asIntOrNull(value) ?? 0;

int? _asIntOrNull(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value == null) return null;
  return int.tryParse(value.toString());
}
