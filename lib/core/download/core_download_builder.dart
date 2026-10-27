import 'dart:io';

import 'download_paths.dart';

/// Rust 内核下载请求的 Dart 镜像。
///
/// 字段与 `gstore_core::download::port::DownloadRequest` 一一对应（不含
/// proxy——Rust 请求类型里没有该字段），确保换内核时参数不会在 Dart 侧
/// 被悄悄丢弃或改名。请求头随 [headers] 原样跨边界转发。
class CoreDownloadRequest {
  final String appId;
  final String appName;
  final String version;
  final String fileName;
  final String url;
  final String destPath;
  final String kind;
  final String resourceId;
  final String resourceVersion;
  final String dedupKey;
  final String? expectedSha256;
  final bool installAfterDownload;
  final Map<String, String> headers;

  const CoreDownloadRequest({
    required this.appId,
    required this.appName,
    required this.version,
    required this.fileName,
    required this.url,
    required this.destPath,
    required this.kind,
    required this.resourceId,
    required this.resourceVersion,
    required this.dedupKey,
    this.expectedSha256,
    this.installAfterDownload = false,
    this.headers = const <String, String>{},
  });
}

/// 内核下载的启动接缝。实现方（真实 FFI 或测试假体）只做“启动并返回任务 id”。
abstract interface class CoreDownloadApi {
  Future<int> start(CoreDownloadRequest request);
}

/// 按与 Rust `LocalDbStrategy` 相同的规则构造 [CoreDownloadRequest]。
///
/// 路径解析统一委托给 [DownloadPaths.resolveSavePath]，保证 Dart / Rust 两条
/// 实现落到同一位置；去重键与资源标识也与 Rust 侧逐字段一致。
class CoreDownloadBuilder {
  CoreDownloadBuilder._();

  static Future<CoreDownloadRequest> build({
    required String appId,
    required String appName,
    required String version,
    required String fileName,
    required String url,
    String? saveFileName,
    String? downloadsDir,
    required String docsDir,
    String? expectedSha256,
    bool installAfterDownload = false,
    Map<String, String>? headers,
  }) async {
    final destPath = await DownloadPaths.resolveSavePath(
      saveFileName: saveFileName,
      fileName: fileName,
      downloadsDirProvider: () async =>
          downloadsDir == null ? null : Directory(downloadsDir),
      docsDirProvider: () async => Directory(docsDir),
    );

    return CoreDownloadRequest(
      appId: appId,
      appName: appName,
      version: version,
      fileName: fileName,
      url: url,
      destPath: destPath,
      kind: 'app',
      resourceId: appId,
      resourceVersion: version,
      dedupKey: 'app:$appId:$version:$fileName',
      expectedSha256: expectedSha256,
      installAfterDownload: installAfterDownload,
      headers: headers ?? const <String, String>{},
    );
  }
}
