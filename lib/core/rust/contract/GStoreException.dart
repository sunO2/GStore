import 'package:gstore/core/rust/generated/contract/envelope.pbenum.dart'
    show StatusCode;

/// Rust 模块统一异常（架构文档 6.6）：所有信封调用失败统一经此模型暴露。
///
/// 按状态码分层：
/// - [GStoreApiException]：4xx 调用方问题（不自动重试，记日志）
/// - [GStoreCancelledException]：499 主动取消（不算错误）
/// - [GStoreModuleException]：5xx 模块内部问题（可重试/降级）
/// - [GStoreFlowException]：3xx 需要流程配合（下载模块/重建实例），内部消费
sealed class GStoreException implements Exception {
  final StatusCode status;
  final String errorCode;
  final String message;
  final String requestId;

  GStoreException({
    required this.status,
    required this.errorCode,
    required this.message,
    required this.requestId,
  });

  bool get retryable => false;

  @override
  String toString() =>
      '${status.name} ($status) $errorCode: $message${requestId.isEmpty ? '' : ' [req=$requestId]'}';
}

/// 4xx：调用方问题（参数错误/模块未找到/方法不存在等）
class GStoreApiException extends GStoreException {
  GStoreApiException({
    required super.status,
    required super.errorCode,
    required super.message,
    super.requestId = '',
  });
}

/// 3xx：需要流程配合（模块未下载/实例已失效），由内部封装消费，通常不冒泡到业务
class GStoreFlowException extends GStoreException {
  GStoreFlowException({
    required super.status,
    required super.errorCode,
    required super.message,
    super.requestId = '',
  });
}

/// 499：主动取消（用户取消/超时），按取消语义处理
class GStoreCancelledException extends GStoreException {
  GStoreCancelledException({
    required super.errorCode,
    required super.message,
    super.requestId = '',
  }) : super(status: StatusCode.STATUS_ABORTED);
}

/// 5xx：模块内部问题（可重试或降级到空结果）
class GStoreModuleException extends GStoreException {
  @override
  final bool retryable;

  GStoreModuleException({
    required super.status,
    required super.errorCode,
    required super.message,
    super.requestId = '',
    this.retryable = false,
  });
}

/// 按状态码把信封响应转换为对应的异常类型（策略映射单点）
GStoreException statusCodeToException({
  required StatusCode status,
  required String errorCode,
  required String message,
  required String requestId,
}) {
  final code = status.value;
  if (code >= 300 && code < 400) {
    return GStoreFlowException(
      status: status,
      errorCode: errorCode,
      message: message,
      requestId: requestId,
    );
  }
  if (code >= 400 && code < 500) {
    if (code == 499) {
      return GStoreCancelledException(
        errorCode: errorCode,
        message: message,
        requestId: requestId,
      );
    }
    return GStoreApiException(
      status: status,
      errorCode: errorCode,
      message: message,
      requestId: requestId,
    );
  }
  // 5xx
  final retryable = status == StatusCode.STATUS_TIMEOUT ||
      status == StatusCode.STATUS_RESOURCE_EXHAUSTED;
  return GStoreModuleException(
    status: status,
    errorCode: errorCode,
    message: message,
    requestId: requestId,
    retryable: retryable,
  );
}
