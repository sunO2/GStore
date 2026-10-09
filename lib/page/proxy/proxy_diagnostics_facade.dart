/// 诊断页（Todo 30）展示层门面契约。
///
/// 冻结的 [ProxyFacade] 只暴露 `ping` / `version` / `events`；诊断页需要
/// `diagnostics.clash_api.*`（回环控制器，**仅诊断**）、`log.*`（日志环）、
/// `rules.*`（规则集）与 `config.generate` / `config.apply`（手动渲染 / 热应用）。
/// 为**不改动冻结契约**，这里定义窄接口 [ProxyDiagnosticsFacade] 并由
/// [ProxyModuleDiagnosticsFacade] 适配 [ProxyModule]。
///
/// **边界（重要）**：
/// * Clash 回环控制器**只用于诊断**，Dart 侧**绝不**经其 HTTP API 处理正常业务；
///   正常业务一律走信封（`core.*` / `stats.*` / `conn.*`）与模块事件。
/// * 响应模型（[ClashApiStatus] 等）**不含 secret**；门面只做薄转发 / 解码。
/// * `config.*` 返回的 `config` 是生成的 Clash YAML，可能含代理凭证——门面原样
///   返回，**由展示层负责不渲染正文**（只展示 hash / 计数 / 警告等摘要）。
library;

import 'package:gstore/core/rust/proxy/ProxyContract.dart';
import 'package:gstore/core/rust/proxy/ProxyModule.dart';

/// 诊断页所需的模块能力（`diagnostics.clash_api.*` / `log.*` / `rules.*` /
/// `config.*`）。
abstract class ProxyDiagnosticsFacade {
  /// `diagnostics.clash_api.start`：启用回环 Clash 控制器（默认 OFF，仅诊断）。
  Future<ClashApiStatus> clashApiStart({int port = 0});

  /// `diagnostics.clash_api.stop`：停止回环 Clash 控制器。
  Future<ClashApiStopResult> clashApiStop();

  /// `diagnostics.clash_api.status`：控制器状态（**不含 secret**）。
  Future<ClashApiStatus> clashApiStatus();

  /// `log.get`：按游标 / 级别读取日志环。
  Future<LogPage> logGet(LogGetRequest request);

  /// `log.set_level`：设置日志保留级别。
  Future<LogSetLevelResult> logSetLevel(String level);

  /// `log.clear`：清空日志环（游标继续前进）。
  Future<OkResult> logClear();

  /// `rules.get`：只读规则快照。
  Future<RulesSnapshot> rulesGet();

  /// `rules.reload`：解析并发布规则集（内联 `config` 或 `configPath`）。
  Future<RulesSnapshot> rulesReload(RulesReloadRequest request);

  /// `config.generate`：渲染受控 Clash 模板（不触碰运行中引擎）。
  Future<GeneratedConfig> configGenerate(GenerateRequest request);

  /// `config.apply`：热应用配置到运行中引擎。
  Future<GeneratedConfig> configApply(GenerateRequest request);
}

/// 生产适配器：[ProxyModule] → [ProxyDiagnosticsFacade] 的薄转发。
class ProxyModuleDiagnosticsFacade implements ProxyDiagnosticsFacade {
  ProxyModuleDiagnosticsFacade([ProxyModule? module])
      : _module = module ?? ProxyModule.instance;

  final ProxyModule _module;

  @override
  Future<ClashApiStatus> clashApiStart({int port = 0}) =>
      _module.clashApiStart(port: port);

  @override
  Future<ClashApiStopResult> clashApiStop() => _module.clashApiStop();

  @override
  Future<ClashApiStatus> clashApiStatus() => _module.clashApiStatus();

  @override
  Future<LogPage> logGet(LogGetRequest request) => _module.logGet(request);

  @override
  Future<LogSetLevelResult> logSetLevel(String level) =>
      _module.logSetLevel(level);

  @override
  Future<OkResult> logClear() => _module.logClear();

  @override
  Future<RulesSnapshot> rulesGet() => _module.rulesGet();

  @override
  Future<RulesSnapshot> rulesReload(RulesReloadRequest request) =>
      _module.rulesReload(request);

  @override
  Future<GeneratedConfig> configGenerate(GenerateRequest request) =>
      _module.configGenerate(request);

  @override
  Future<GeneratedConfig> configApply(GenerateRequest request) =>
      _module.configApply(request);
}
