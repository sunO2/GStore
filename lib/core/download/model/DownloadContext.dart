import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';

/// 下载上下文 - 封装渠道特定的下载配置
class DownloadContext {
  /// 原始下载URL
  final String originalUrl;

  /// 最终下载URL（经过代理转换等处理）
  String? finalUrl;

  /// 自定义请求头
  Map<String, String>? headers;

  /// 代理服务器地址
  String? proxy;

  /// 下载超时时间（秒）
  int? timeoutInSeconds;

  /// 是否支持断点续传
  bool supportBreakpoint;

  /// 渠道类型
  final ChannelType channelType;

  /// 渠道特定元数据
  final Map<String, dynamic> metadata;

  /// 文件名
  final String fileName;

  /// 文件大小
  final int? fileSize;

  /// 版本号
  final String? version;

  DownloadContext({
    required this.originalUrl,
    required this.channelType,
    required this.fileName,
    this.fileSize,
    this.version,
    this.finalUrl,
    this.headers,
    this.proxy,
    this.timeoutInSeconds,
    this.supportBreakpoint = true,
    Map<String, dynamic>? metadata,
  }) : metadata = metadata ?? {};

  /// 获取用于下载的URL
  String get downloadUrl => finalUrl ?? originalUrl;

  /// 是否需要代理
  bool get needsProxy => proxy != null && proxy!.isNotEmpty;

  /// 是否需要自定义headers
  bool get hasCustomHeaders => headers != null && headers!.isNotEmpty;

  /// 创建副本并修改部分字段
  DownloadContext copyWith({
    String? originalUrl,
    String? finalUrl,
    Map<String, String>? headers,
    String? proxy,
    int? timeoutInSeconds,
    bool? supportBreakpoint,
    ChannelType? channelType,
    Map<String, dynamic>? metadata,
    String? fileName,
    int? fileSize,
    String? version,
  }) {
    return DownloadContext(
      originalUrl: originalUrl ?? this.originalUrl,
      channelType: channelType ?? this.channelType,
      fileName: fileName ?? this.fileName,
      fileSize: fileSize ?? this.fileSize,
      version: version ?? this.version,
      finalUrl: finalUrl ?? this.finalUrl,
      headers: headers ?? this.headers,
      proxy: proxy ?? this.proxy,
      timeoutInSeconds: timeoutInSeconds ?? this.timeoutInSeconds,
      supportBreakpoint: supportBreakpoint ?? this.supportBreakpoint,
      metadata: metadata ?? Map.from(this.metadata),
    );
  }

  @override
  String toString() {
    return 'DownloadContext{originalUrl: $originalUrl, finalUrl: $finalUrl, '
        'channelType: $channelType, proxy: $proxy, '
        'hasHeaders: $hasCustomHeaders, supportBreakpoint: $supportBreakpoint}';
  }
}
