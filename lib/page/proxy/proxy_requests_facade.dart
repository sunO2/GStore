/// 请求域名 / IP 收集页（Todo 14）展示层门面契约。
///
/// 冻结的 [ProxyFacade] 只暴露 `ping` / `version` / `events`；收集页需要
/// `requests.get` / `requests.reset` / `requests.export`。为**不改动冻结契约**，
/// 这里定义窄接口 [ProxyRequestsFacade] 并由 [ProxyModuleRequestsFacade] 适配
/// [ProxyModule]。
///
/// **纯展示层**：分页 / 筛选 / 导出格式都只是转发参数；请求时间线、游标、
/// 淘汰计数与 CSV/JSON 生成全部在 Rust 侧（`API.md` §2.14），Dart 仅按字段
/// 展示，**不聚合、不落盘**（导出文件由 Rust 写入模块数据目录，UI 另存）。
///
/// 契约措辞 `ExportRequest` 在 `ProxyContract.dart` 中的实现名为
/// [RequestExportRequest]（契约已冻结，此处直接复用，不新增别名）。
library;

import 'package:gstore/core/rust/proxy/ProxyContract.dart';
import 'package:gstore/core/rust/proxy/ProxyModule.dart';

/// 收集页所需的模块能力（`requests.get` / `requests.reset` /
/// `requests.export`）。
abstract class ProxyRequestsFacade {
  /// `requests.get`：按游标分页拉取请求时间线（拉取式主路径）。
  Future<RequestPage> requestsGet(RequestGetRequest request);

  /// `requests.reset`：清空内存请求环与 DB 行（游标保持单调，不回收）。
  Future<void> requestsReset();

  /// `requests.export`：把请求时间线导出为 CSV 和/或 JSON 文件。
  ///
  /// 响应仅回传文件路径 / 行数 / 字节数（记录只写入文件，不进 JSON 信封）。
  Future<RequestExportResult> requestsExport(RequestExportRequest request);
}

/// 生产适配器：[ProxyModule] → [ProxyRequestsFacade] 的薄转发。
class ProxyModuleRequestsFacade implements ProxyRequestsFacade {
  ProxyModuleRequestsFacade([ProxyModule? module])
      : _module = module ?? ProxyModule.instance;

  final ProxyModule _module;

  @override
  Future<RequestPage> requestsGet(RequestGetRequest request) =>
      _module.requestsGet(request);

  @override
  Future<void> requestsReset() async {
    await _module.requestsReset();
  }

  @override
  Future<RequestExportResult> requestsExport(RequestExportRequest request) =>
      _module.requestsExport(request);
}
