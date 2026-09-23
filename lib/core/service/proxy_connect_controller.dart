/// 代理连接 / 断开编排器（UI 无关，依赖全部注入）。
///
/// 把代理首页「连接」按钮背后的完整序列抽成**可复用**协调器，供代理首页与未来
/// 的快捷设置磁贴（Android `ACTION_PROXY_CONNECT` 意图处理器）共用同一流程：
///
/// * 连接：VPN 目标时先拉起系统授权 `prepare` → 门面 `core.start` →
///   重放持久化的路由模式（`routing.set_mode`）；
/// * 断开：门面 `core.stop` → 尽力而为停系统前台服务（`try/finally` 兜底，
///   停服务失败绝不覆盖 `core.stop` 的原始错误）。
///
/// 本类**不含 UI**：不 `setState`、不弹层、不打日志，只在无组件上下文中调用门面 /
/// 授权接缝，把**已解码的契约模型**返回给调用方，由调用方更新自身状态。所有依赖
/// 经构造函数传入（窄门面 [ProxyConnectFacade] + 授权 [ProxyVpnConsent] + 两个
/// 持久化存储），单元测试可注入内存假实现，无需原生模块 / 平台通道。
///
/// 行为与重构前的首页内联实现逐项对齐（prepare → core.start → 路由重放的顺序、
/// 各类错误的传播 / 吞掉边界完全一致）。
library;

import 'package:gstore/core/rust/proxy/ProxyContract.dart';
import 'package:gstore/core/rust/proxy/ProxyModule.dart';
import 'package:gstore/page/proxy/proxy_engine_settings_store.dart';
import 'package:gstore/page/proxy/proxy_geo_provisioner.dart';
import 'package:gstore/page/proxy/proxy_home_facade.dart';
import 'package:gstore/page/proxy/proxy_routing_mode_store.dart';

/// 一次成功连接的结果。
class ProxyConnectOutcome {
  const ProxyConnectOutcome({required this.status, this.routingMode});

  /// `core.start` 的响应（引擎状态 / 模式 / 订阅名 / 配置警告）。
  final ProxyCoreStatus status;

  /// 重放持久化路由模式后引擎回报的模式；未重放 / 重放失败 / 引擎回报
  /// `unknown` 时为 `null`（调用方应保持原选择）。
  final ProxyRoutingMode? routingMode;
}

/// 代理连接 / 断开编排器。
class ProxyConnectController {
  ProxyConnectController({
    required this.facade,
    required this.vpnConsent,
    required this.engineSettingsStore,
    required this.routingModeStore,
    this.geoProvisioner,
    this.defaultVpnConfigJson = '{}',
  });

  /// 连接控制门面（生产为 [ProxyModuleHomeFacade]，测试可注入窄假实现）。
  final ProxyConnectFacade facade;

  /// VPN 授权 / 前台服务触发接缝（生产走平台通道）。
  final ProxyVpnConsent vpnConsent;

  /// 引擎侧设置（stack / MTU）读取接缝。
  final ProxyEngineSettingsStore engineSettingsStore;

  /// 用户选择的路由模式读取接缝（连接成功后重放）。
  final ProxyRoutingModeStore routingModeStore;

  /// 规则模式 geo provisioning 接缝（可选，默认 `null` = 不参与）。
  ///
  /// 生产页面的 provisioner 需异步加载清单（[ProxyGeoProvisionerFactory]），
  /// 因此本字段**可变**：页面构造协调器后再回填。连接前若目标路由模式为 `rule`
  /// 则 best-effort `kickoff`（只 spawn 后台下载，不阻塞连接）。
  ProxyGeoProvisioner? geoProvisioner;

  /// 未显式传入 VPN 配置时的默认值（与 Kotlin 侧 `{}` = 全量路由一致）。
  final String defaultVpnConfigJson;

  /// 执行一次连接：`prepare`（仅 VPN）→ `core.start` → 重放持久化路由模式。
  ///
  /// [targetMode] 用户选择的运行模式（vpn / lanProxy）；[profileId] 选中订阅 id；
  /// [vpnConfigJson] 显式传入的 VPN 配置（`null` / 默认 `{}` 时回落到门面
  /// `vpnConfigJson()`）；[fallbackRoutingMode] 存储未命中时的路由模式兜底。
  ///
  /// 授权被拒抛 `ProxyModuleException(PROXY_VPN_CONSENT_DENIED)`；`core.start`
  /// 的错误原样抛出（不吞），与首页原实现一致。
  Future<ProxyConnectOutcome> connect({
    required ProxyMode targetMode,
    String? profileId,
    String? vpnConfigJson,
    ProxyRoutingMode? fallbackRoutingMode,
  }) async {
    if (targetMode == ProxyMode.vpn) {
      // 连接必须带上持久化的分流配置（Todo 23 → Todo 24 交接）：仅在显式传入
      // 非默认配置时才直接使用，否则向门面读取。
      var configJson = vpnConfigJson ?? defaultVpnConfigJson;
      if (configJson == defaultVpnConfigJson) {
        configJson = await _safeVpnConfigJson() ?? configJson;
      }
      final prepared = await vpnConsent.prepare(configJson: configJson);
      if (!prepared) {
        throw const ProxyModuleException(
          code: 'PROXY_VPN_CONSENT_DENIED',
          message: 'VPN 授权未通过，无法建立连接',
        );
      }
    }
    final settings = await _readEngineSettings();
    // 规则模式依赖 geo 数据（GEOIP,CN / GEOSITE,cn）：引擎启动前 best-effort
    // 触发后台下载。kickoff 只 spawn 下载、立即返回，不增加连接延迟；失败绝不
    // 阻断连接（见 [_maybeKickoffGeo]）。
    await _maybeKickoffGeo(
      profileId: profileId,
      fallbackRoutingMode: fallbackRoutingMode,
    );
    final status = await facade.coreStart(
      CoreStartRequest(
        mode: targetMode.wire,
        profileId: profileId,
        stack: settings.stack,
        mtu: settings.mtu,
      ),
    );
    // 新隧道默认 rule：连接成功后重放持久化的路由模式。
    final routingMode = await replayPersistedRoutingMode(
      fallbackRoutingMode: fallbackRoutingMode,
    );
    return ProxyConnectOutcome(status: status, routingMode: routingMode);
  }

  /// 断开连接：`core.stop` → 停系统前台服务（`try/finally` 兜底）。
  ///
  /// `core.stop` 抛错时错误原样传播，但**仍**会尝试停服务（避免系统 `VpnService`
  /// 残留持有 TUN）；停服务自身异常被吞掉，绝不覆盖 `core.stop` 的原始错误。
  /// 返回 `core.stop` 的响应（停止后的状态）。
  Future<CoreStopResult?> disconnect() async {
    CoreStopResult? stopped;
    try {
      stopped = await facade.coreStop();
    } finally {
      await _safeStopVpnService();
    }
    return stopped;
  }

  /// 把持久化的路由模式重放给引擎，返回引擎回报的新模式。
  ///
  /// best-effort：存储读取 / `routing.set_mode` 失败，或引擎回报 `unknown` 时
  /// 返回 `null`（调用方保持原选择），绝不抛错。存储未命中时用
  /// [fallbackRoutingMode] 兜底。
  Future<ProxyRoutingMode?> replayPersistedRoutingMode({
    ProxyRoutingMode? fallbackRoutingMode,
  }) async {
    final stored = await _safeReadRoutingMode();
    final target = stored ?? fallbackRoutingMode;
    if (target == null || target == ProxyRoutingMode.unknown) return null;
    final result = await _safeSetRoutingMode(target.wire);
    if (result == null || result.mode == ProxyRoutingMode.unknown) return null;
    return result.mode;
  }

  /// best-effort 读取 VPN 配置：门面失败降级为 `null`（回落默认 `{}`）。
  Future<String?> _safeVpnConfigJson() async {
    try {
      return await facade.vpnConfigJson();
    } catch (_) {
      return null;
    }
  }

  /// 读取持久化的引擎侧设置；存储异常时回落默认值（绝不抛错）。
  Future<ProxyEngineSettings> _readEngineSettings() async {
    try {
      return await engineSettingsStore.read();
    } catch (_) {
      return const ProxyEngineSettings();
    }
  }

  /// best-effort 读取持久化路由模式：失败 / 未设置返回 `null`。
  Future<ProxyRoutingMode?> _safeReadRoutingMode() async {
    try {
      return await routingModeStore.read();
    } catch (_) {
      return null;
    }
  }

  /// 目标路由模式为 `rule` 时 best-effort 触发一次 geo provisioning。
  ///
  /// 读取持久化模式（未设置 / 失败 / `unknown` 用 [fallbackRoutingMode] 兜底）；
  /// 非 `rule`（`direct` / `global` / 空）直接跳过。provisioner 未注入时跳过。
  ///
  /// kickoff 自身承诺绝不抛异常，此处再兜一层 `try/catch`，确保 geo 的任何失败都
  /// **绝不**阻断连接；且 kickoff 只负责快速 spawn 后台下载，不等待下载完成。
  Future<void> _maybeKickoffGeo({
    String? profileId,
    ProxyRoutingMode? fallbackRoutingMode,
  }) async {
    final provisioner = geoProvisioner;
    if (provisioner == null) return;
    final stored = await _safeReadRoutingMode();
    final target = stored ?? fallbackRoutingMode;
    if (target != ProxyRoutingMode.rule) return;
    try {
      await provisioner.kickoff(profileId: profileId);
    } catch (_) {
      // best-effort：geo 触发失败不得影响连接建立。
    }
  }

  /// best-effort 重放路由模式：失败返回 `null`。
  Future<RoutingModeSetResult?> _safeSetRoutingMode(String mode) async {
    try {
      return await facade.routingSetMode(mode);
    } catch (_) {
      return null;
    }
  }

  /// best-effort 停系统前台服务：异常静默（不得覆盖 `core.stop` 原始错误）。
  Future<void> _safeStopVpnService() async {
    try {
      await vpnConsent.stop();
    } catch (_) {
      // 拆除尽力而为。
    }
  }
}
