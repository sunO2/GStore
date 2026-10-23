import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:gstore/core/core_flags.dart';

import 'download_paths.dart';

/// Rust 内核下载请求的 Dart 镜像。
///
/// 字段与 `gstore_core::download::port::DownloadRequest` 一一对应（不含
/// proxy/header——Rust 请求类型里没有这两个字段），确保换内核时参数不会
/// 在 Dart 侧被悄悄丢弃或改名。
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
    );
  }

  /// 仅在 [CoreFlags.download] 打开时启动内核下载。
  ///
  /// 返回 null 表示“未启用 / 未启动”，调用方应继续走旧的 Dart 路径；
  /// 关闭时**绝不**触碰 [api]，避免出现一半新一半旧的混跑。
  ///
  /// 镜像为关闭时先刷新一次：开关可能是别的路径在最后一次读取后打开的。
  /// 刷新失败保持镜像原值并降级到旧路径，绝不让开关后端故障阻断下载。
  static Future<int?> startIfEnabled(
    CoreDownloadApi api,
    CoreDownloadRequest request,
  ) async {
    if (!await _downloadEnabled()) {
      return null;
    }
    return api.start(request);
  }

  static Future<bool> _downloadEnabled() async {
    if (!CoreFlags.download) {
      try {
        await CoreFlags.refresh();
      } catch (error) {
        debugPrint('CoreDownloadBuilder: 刷新 download 开关失败（保持镜像原值）: $error');
      }
    }
    return CoreFlags.download;
  }
}
