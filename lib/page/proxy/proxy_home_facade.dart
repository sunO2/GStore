/// 代理首页（Todo 19）的展示层接缝。
///
/// 目的：让 [ProxyHomePage] 既不依赖原生模块、也不依赖 MethodChannel，
/// 组件测试可注入假实现。**只做转发**，不含任何解析 / 网络 / 路由 / 统计逻辑
/// （逻辑一律在 Rust 的 `gstore_mod_proxy`，见 [ProxyModule] 头部说明）。
///
/// 冻结契约 [ProxyFacade]（`ProxyModule.dart`）是**只读**的（ping/version/events）；
/// 首页还需要「连接 / 断开」动作，因此在**本页文件**内扩展为 [ProxyHomeFacade]
/// （`implements ProxyFacade`），并由 [ProxyModuleHomeFacade] 适配冻结的
/// [ProxyModule]。这不修改任何冻结文件。
library;

import 'package:gstore/core/rust/proxy/ProxyContract.dart';
import 'package:gstore/core/rust/proxy/ProxyModule.dart';
import 'package:gstore/core/service/proxy_vpn_service.dart';
import 'package:gstore/page/proxy/proxy_settings_facade.dart';

/// 首页所需的门面能力 = 冻结的只读 [ProxyFacade] + 连接控制 + 只读展示数据。
///
/// 所有方法都只是把请求转发给模块并返回**已解码的契约模型**；数值/口径由 Rust
/// 计算（如 `statsTrafficGet` 的 topDomains 排序），Dart 仅渲染。
abstract class ProxyHomeFacade implements ProxyFacade {
  /// `core.start`：按生成配置启动引擎（连接动作，须先取得 TUN 授权）。
  Future<ProxyCoreStatus> coreStart(CoreStartRequest request);

  /// `core.stop`：停止引擎并释放 TUN（断开动作）。
  Future<CoreStopResult> coreStop();

  /// `core.get_mode`：当前模式 + 状态 + 持久化的上次使用模式。
  Future<CoreModeResult> coreGetMode();

  /// `core.set_mode`：实时切换运行模式（`off`/`vpn`/`lanProxy`）。
  ///
  /// 模式状态机完全在 Rust；本方法只是请求。`lanProxy` 在 LAN 未启用时由模块
  /// 返回结构化 `PROXY_NO_INBOUND`，绝不静默 no-op。
  Future<CoreSetModeResult> coreSetMode(String mode);

  /// `lan.status`：只读 LAN 监听状态，供首页在切换到 `lanProxy` 前提示。
  Future<ProxyLanStatus> lanStatus();

  /// `stats.traffic.get`：聚合流量快照（含 Rust 排序后的 topDomains）。
  Future<TrafficSnapshot> statsTrafficGet({int? topDomains});

  /// `profile.list`：稳定的订阅摘要（只读展示当前配置）。
  Future<ProfileList> profileList();

  /// `node.list`：各代理组的实时选中（`now`）与当前路由分组（只读）。
  Future<NodeListResult> nodeList();

  /// 读取持久化设置生成的 Kotlin `ProxyVpnService` 配置 JSON（含分流模式/应用
  /// 清单）。连接前注入，不得硬编码 `{}`（Todo 23 → Todo 24 交接）。
  Future<String> vpnConfigJson();
}

/// 生产适配器：把 [ProxyHomeFacade] 转发到冻结的 [ProxyModule] 单例。
///
/// 构造不触碰 FFI；只有调用方法时才经模块自举（首次使用按需安装）。
class ProxyModuleHomeFacade implements ProxyHomeFacade {
  ProxyModuleHomeFacade([ProxyModule? module])
      : _module = module ?? ProxyModule.instance;

  final ProxyModule _module;

  @override
  Future<ProxyPingResult> ping() => _module.ping();

  @override
  Future<ProxyVersionInfo> version() => _module.version();

  @override
  Stream<ProxyEvent> get events => _module.events;

  @override
  Future<ProxyCoreStatus> coreStart(CoreStartRequest request) =>
      _module.coreStart(request);

  @override
  Future<CoreStopResult> coreStop() => _module.coreStop();

  @override
  Future<CoreModeResult> coreGetMode() => _module.coreGetMode();

  @override
  Future<CoreSetModeResult> coreSetMode(String mode) => _module.coreSetMode(mode);

  @override
  Future<ProxyLanStatus> lanStatus() =>
      _module.invoke('lan.status', ProxyLanStatus.fromJson);

  @override
  Future<TrafficSnapshot> statsTrafficGet({int? topDomains}) =>
      _module.statsTrafficGet(topDomains: topDomains);

  @override
  Future<ProfileList> profileList() => _module.profileList();

  @override
  Future<NodeListResult> nodeList() => _module.nodeList();

  @override
  Future<String> vpnConfigJson() => loadProxyVpnConfigJson();
}

/// Android VPN 授权 / 前台服务触发接缝（[ProxyVpnTrigger] 的可注入包装）。
///
/// 仅负责拉起系统授权流程与前台服务；不含任何 VPN 逻辑（在 Kotlin 侧）。
abstract class ProxyVpnConsent {
  /// 触发系统 VPN 同意对话框；已授权时直接启动服务。返回通道是否成功转发。
  Future<bool> prepare({String configJson});

  /// 停止前台服务。
  Future<bool> stop();

  /// 前台服务当前是否在运行（always-on 重启后用于恢复 Rust 引擎状态）。
  Future<bool> isRunning();
}

/// 生产实现：经 [ProxyVpnTrigger] 的平台通道。
class PlatformProxyVpnConsent implements ProxyVpnConsent {
  const PlatformProxyVpnConsent();

  @override
  Future<bool> prepare({String configJson = '{}'}) =>
      ProxyVpnTrigger.prepare(configJson: configJson);

  @override
  Future<bool> stop() => ProxyVpnTrigger.stop();

  @override
  Future<bool> isRunning() => ProxyVpnTrigger.isRunning();
}
