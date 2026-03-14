import 'ChannelType.dart';

/// 统一的渠道返回结果
class ChannelResult<T> {
  /// 返回的数据
  final T? data;

  /// 数据来源渠道
  final ChannelType from;

  /// 是否成功
  final bool success;

  /// 错误信息
  final String? error;

  /// 是否来自缓存
  final bool fromCache;

  /// 额外元数据
  final Map<String, dynamic>? metadata;

  ChannelResult({
    this.data,
    required this.from,
    this.success = true,
    this.error,
    this.fromCache = false,
    this.metadata,
  });

  /// 创建成功结果
  factory ChannelResult.success({
    required T data,
    required ChannelType from,
    bool fromCache = false,
    Map<String, dynamic>? metadata,
  }) {
    return ChannelResult(
      data: data,
      from: from,
      success: true,
      fromCache: fromCache,
      metadata: metadata,
    );
  }

  /// 创建失败结果
  factory ChannelResult.failure({
    required ChannelType from,
    required String error,
    T? data,
  }) {
    return ChannelResult(
      data: data,
      from: from,
      success: false,
      error: error,
    );
  }

  @override
  String toString() {
    return 'ChannelResult{from: $from, success: $success, fromCache: $fromCache, data: $data}';
  }
}
