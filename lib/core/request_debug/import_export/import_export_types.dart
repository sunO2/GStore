/// 「请求调试」导入 / 导出：结构化结果与格式枚举（plan todo 16）。
///
/// **纯逻辑**：不依赖 IO / UI / 平台通道。所有解码入口在遇到非法 / 截断 / 结构
/// 不符的输入时返回 [DebugTransferResult.failure]，**绝不抛异常**给调用方。
library;

/// 支持的集合导入 / 导出格式。
enum DebugTransferFormat {
  /// HAR 1.2（HTTP Archive）。
  har('har', 'HAR 1.2', 'har'),

  /// Postman Collection v2.1。
  postman('postman', 'Postman v2.1', 'json'),

  /// OpenAPI 3（**仅 JSON**；不引入 YAML 依赖）。
  openapi('openapi', 'OpenAPI 3', 'json'),

  /// 原始 HTTP 请求文本（`.http` / REST Client 风格，`###` 分隔多请求）。
  rawHttp('raw_http', '原始 HTTP', 'http');

  const DebugTransferFormat(this.wire, this.label, this.defaultExtension);

  /// 持久化 / 展示用的稳定标识。
  final String wire;

  /// 中文展示名。
  final String label;

  /// 导出默认文件扩展名（不含点）。
  final String defaultExtension;
}

/// 结构化错误类型。
enum DebugTransferErrorKind {
  /// 输入为空 / 全为空白。
  empty,

  /// JSON 语法错误（含截断）。
  invalidJson,

  /// JSON 合法但结构不符（缺关键节点 / 类型错误）。
  invalidStructure,

  /// 无法识别的格式。
  unsupportedFormat,
}

/// 结构化错误（含面向用户的说明）。
class DebugTransferError {
  const DebugTransferError(this.kind, this.message);

  final DebugTransferErrorKind kind;
  final String message;

  @override
  String toString() => 'DebugTransferError(${kind.name}): $message';
}

/// 编解码结果：成功携带值，失败携带结构化错误（二者互斥）。
class DebugTransferResult<T> {
  const DebugTransferResult.success(this.value) : error = null;

  const DebugTransferResult.failure(this.error) : value = null;

  final T? value;
  final DebugTransferError? error;

  bool get isSuccess => error == null;

  /// 成功时返回值；失败时抛 [StateError]（仅用于调用方已确认成功的场景）。
  T requireValue() {
    final v = value;
    if (v == null) {
      throw StateError('解码失败：${error?.message ?? '未知错误'}');
    }
    return v;
  }
}
