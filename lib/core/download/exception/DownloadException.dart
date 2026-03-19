/// 下载相关异常定义
library;

/// 下载策略异常
/// 当下载策略创建或验证失败时抛出
class DownloadStrategyException implements Exception {
  /// 错误消息
  final String message;

  /// 渠道类型
  final String? channelType;

  /// 原始异常
  final dynamic originalError;

  DownloadStrategyException(
    this.message, {
    this.channelType,
    this.originalError,
  });

  @override
  String toString() {
    final buffer = StringBuffer('DownloadStrategyException: $message');
    if (channelType != null) {
      buffer.write(' (channel: $channelType)');
    }
    if (originalError != null) {
      buffer.write('\nCaused by: $originalError');
    }
    return buffer.toString();
  }
}

/// 下载上下文验证异常
/// 当下载上下文验证失败时抛出
class DownloadContextValidationException extends DownloadStrategyException {
  DownloadContextValidationException(
    super.message, {
    super.channelType,
    super.originalError,
  });
}

/// 下载URL构建异常
/// 当无法构建有效的下载URL时抛出
class DownloadUrlBuildException extends DownloadStrategyException {
  DownloadUrlBuildException(
    super.message, {
    super.channelType,
    super.originalError,
  });
}
