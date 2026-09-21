/// 代理日志查看器（Todo 22b）展示层门面 + 日志源契约。
///
/// 冻结的 [ProxyFacade] 只暴露 `ping` / `version` / `events`；日志页需要
/// `log.get` / `log.set_level`。为**不改动冻结契约**，这里定义窄接口
/// [ProxyLogsFacade] 并由 [ProxyModuleLogsFacade] 适配 [ProxyModule]。
///
/// 模块日志经宿主 `log` 回调写入 [LogManager]（push），本页实时展示；
/// `log.get` 提供连接 / DNS 结构化条目（pull）。两者均只转发 / 渲染。
library;

import 'package:gstore/core/logger/LogManager.dart';
import 'package:gstore/core/rust/proxy/ProxyContract.dart';
import 'package:gstore/core/rust/proxy/ProxyModule.dart';

/// 日志页所需的模块能力（`log.get` / `log.set_level`）。
abstract class ProxyLogsFacade {
  /// `log.get`：按游标 / 级别读取日志环。
  Future<LogPage> logGet(LogGetRequest request);

  /// `log.set_level`：设置日志保留级别。
  Future<LogSetLevelResult> logSetLevel(String level);
}

/// 生产适配器：[ProxyModule] → [ProxyLogsFacade] 的薄转发。
class ProxyModuleLogsFacade implements ProxyLogsFacade {
  ProxyModuleLogsFacade([ProxyModule? module])
      : _module = module ?? ProxyModule.instance;

  final ProxyModule _module;

  @override
  Future<LogPage> logGet(LogGetRequest request) => _module.logGet(request);

  @override
  Future<LogSetLevelResult> logSetLevel(String level) =>
      _module.logSetLevel(level);
}

/// 模块日志源（`LogManager` 推送；测试可注入假实现）。
abstract class ProxyLogSource {
  /// 当前快照（live 列表，仅读）。
  List<LogEntry> get logs;

  /// 变更流（新增日志时推送最新列表）。
  Stream<List<LogEntry>> get stream;
}

/// 生产日志源：全局 [LogManager] 单例。
class ManagerProxyLogSource implements ProxyLogSource {
  const ManagerProxyLogSource();

  @override
  List<LogEntry> get logs => LogManager.instance.logs;

  @override
  Stream<List<LogEntry>> get stream => LogManager.instance.logsStream;
}
