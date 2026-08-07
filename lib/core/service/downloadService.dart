import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:gstore/http/download/DownloadStatus.dart';
import 'package:gstore/core/core.dart';
import 'package:dio/dio.dart';
import 'package:gstore/http/download/DownloadStatusDataBase.dart';
import 'package:gstore/core/download/model/DownloadContext.dart';
import 'package:gstore/core/service/download_notification_service.dart';
import 'package:gstore/core/service/apk_info_service.dart';

/// 下载数据库（兼容旧代码引用，已内部缓存单例）
final Future<DownloadDatabase> database = downloadStatusDatabase;

/// 下载并发控制信号量
/// 限制同时进行的下载任务数量，避免资源耗尽
class DownloadSemaphore {
  final int _maxConcurrent;
  int _active = 0;
  final List<Completer<void>> _queue = [];

  DownloadSemaphore(this._maxConcurrent);

  /// 获取执行许可（排队等待）
  Future<void> acquire() async {
    if (_active < _maxConcurrent) {
      _active++;
      return;
    }

    final completer = Completer<void>();
    _queue.add(completer);
    await completer.future;
    _active++;
  }

  /// 释放许可
  void release() {
    _active--;
    if (_queue.isNotEmpty) {
      final next = _queue.removeAt(0);
      next.complete();
    }
  }

  /// 当前活跃任务数
  int get active => _active;

  /// 排队任务数
  int get queued => _queue.length;
}

class DownloadService extends GetxService {
  final Dio _dio;

  /// 最大并发下载数
  static const int maxConcurrentDownloads = 3;

  /// 失败重试次数
  static const int maxRetryCount = 3;

  final DownloadSemaphore _semaphore =
      DownloadSemaphore(maxConcurrentDownloads);

  DownloadService(this._dio);
  /// appid 包名
  /// appName 应用名称
  /// version 版本
  /// url 下载地址
  /// fileName 文件名
  /// downloadSize 文件大小
  /// breakPoint 是否支持断点续传
  /// saveName 保存的文件名
  Future<DownloadStatus> download(String appid, appName, version, url, fileName,
      {int? downloadSize, bool breakPoint = true, String? saveFileName,
      bool forceDownload = false}) async {
    appLog.info('DownloadService.download 开始: appid=$appid version=$version url=$url forceDownload=$forceDownload');
    // 请求通知权限（Android 13+ 首次下载时询问）
    DownloadNotificationService.instance.requestPermission();
    // 检查是否正在下载
    if (DownloadStatus.isDownloading(appid, version, fileName)) {
      appLog.info("文件正在下载中，跳过重复下载: $fileName");
      // 返回现有的下载状态
      final existing = await (await (await database)
          .downloadStatusDao
          .getDownloadOfName(fileName, version));
      if (existing != null) {
        return existing;
      }
    }

    // 获取或创建下载状态
    var existing = await (await database)
        .downloadStatusDao
        .getDownloadOfName(fileName, version);
    debugPrint('DownloadService: 查找到已有记录: ${existing != null}'
        '${existing != null ? ' savePath=${existing!.savePath} status=${existing.status}' : ''}');
    // 若调用方传了新的保存路径，且与已有记录路径不一致，则删除旧记录重新创建
    // （否则会复用旧 savePath，导致下载写入错误位置）
    if (existing != null &&
        saveFileName != null &&
        existing.savePath != saveFileName) {
      debugPrint('DownloadService: 保存路径已变化，重建下载记录: '
          '${existing.savePath} -> $saveFileName');
      final eid = existing.id;
      if (eid != null) {
        await (await database).downloadStatusDao.deleteDownload(eid);
      }
      existing = null;
    }
    var downloadStatus = existing ??
        (await DownloadStatus.create(appid, appName, version, fileName, url,
            downloadSize: downloadSize, saveFileName: saveFileName));
    debugPrint('DownloadService: 下载状态已创建, status=${downloadStatus.status}, savePath=${downloadStatus.savePath}');
    // 若非强制下载，且已下载成功，直接返回（跳过重复下载）
    if (!forceDownload &&
        downloadStatus.status == DownloadStatus.DOWNLOAD_SUCCESS &&
        _install(fileName, downloadStatus.savePath)) {
      appLog.info('DownloadService: 已下载成功，跳过重复下载');
      return downloadStatus;
    }

    // 强制下载时，清除旧的临时文件，从头下载
    if (forceDownload) {
      debugPrint('DownloadService: 强制重新下载，清理旧文件');
      final tempFile = File("${downloadStatus.savePath}.temp");
      if (await tempFile.exists()) {
        await tempFile.delete();
      }
    }

    // 标记为正在下载
    downloadStatus.markAsDownloading();

    // 等待并发许可
    debugPrint('DownloadService: 等待并发许可 (活跃: ${_semaphore.active})');
    await _semaphore.acquire();
    appLog.info('DownloadService: 已获取并发许可，开始执行下载');
    try {
      await _performDownload(
        downloadStatus,
        breakPoint: breakPoint,
      );
    } finally {
      _semaphore.release();
    }
    appLog.info('DownloadService: 下载执行完成, 最终状态: ${downloadStatus.status}');
    return downloadStatus;
  }

  /// 使用下载上下文下载文件（新方法）
  /// 支持：
  /// - 自定义请求头（headers）
  /// - 代理服务器（proxy）
  /// - URL转换（finalUrl）
  /// - 超时设置（timeoutInSeconds）
  ///
  /// [context] 下载上下文，包含所有下载配置信息
  /// [appid] 应用ID
  /// [appName] 应用名称
  /// [version] 版本号
  /// [fileName] 文件名
  /// [breakPoint] 是否支持断点续传
  /// [saveFileName] 保存的文件名
  Future<DownloadStatus> downloadWithContext(
    DownloadContext context,
    String appid,
    String appName,
    String version,
    String fileName, {
    bool breakPoint = true,
    String? saveFileName,
  }) async {
    // 检查是否正在下载
    if (DownloadStatus.isDownloading(appid, version, fileName)) {
      appLog.info("文件正在下载中，跳过重复下载: $fileName");
      // 返回现有的下载状态
      final existing = await (await (await database)
          .downloadStatusDao
          .getDownloadOfName(fileName, version));
      if (existing != null) {
        return existing;
      }
    }

    var downloadStatus = (await (await database)
            .downloadStatusDao
            .getDownloadOfName(fileName, version)) ??
        (await DownloadStatus.create(
          appid,
          appName,
          version,
          fileName,
          context.downloadUrl,
          downloadSize: context.fileSize,
          saveFileName: saveFileName,
        ));

    if (downloadStatus.status == DownloadStatus.DOWNLOAD_SUCCESS &&
        _install(fileName, downloadStatus.savePath)) {
      return downloadStatus;
    }

    // 标记为正在下载
    downloadStatus.markAsDownloading();

    // 等待并发许可
    await _semaphore.acquire();
    try {
      await _performDownload(
        downloadStatus,
        context: context,
        breakPoint: breakPoint,
      );
    } finally {
      _semaphore.release();
    }

    return downloadStatus;
  }

  /// 执行实际下载（支持断点续传、非Range服务器处理、失败自动重试）
  Future<void> _performDownload(
    DownloadStatus downloadStatus, {
    DownloadContext? context,
    bool breakPoint = true,
  }) async {
    final file = File(downloadStatus.savePath);
    var downloadTempFile = File("${file.path}.temp");
    // 确保目录存在
    await file.parent.create(recursive: true);

    // 通知栏进度（下载开始）
    final notifId = downloadStatus.id ?? downloadStatus.appId.hashCode;
    final notifTitle = downloadStatus.appName.isNotEmpty
        ? downloadStatus.appName
        : downloadStatus.appId;
    DownloadNotificationService.instance.onDownloadStart(
      notifId,
      notifTitle,
      downloadStatus.fileName,
    );

    int attempt = 0;
    while (attempt <= maxRetryCount) {
      if (attempt > 0) {
        appLog.info("重试下载 (${attempt}/$maxRetryCount): ${downloadStatus.fileName}");
        // 退避等待
        await Future.delayed(Duration(seconds: attempt * 2));
      }

      int start = 0;
      // 获取已下载的文件大小
      if (breakPoint && await downloadTempFile.exists()) {
        start = await downloadTempFile.length();
      }

      // 构建请求头
      final requestHeaders = <String, String>{
        'Range': 'bytes=$start-',
        ...?context?.headers,
      };

      // 配置请求选项
      final options = Options(
        headers: requestHeaders,
        responseType: ResponseType.stream,
      );

      // 设置超时
      if (context?.timeoutInSeconds != null) {
        options.sendTimeout = Duration(seconds: context!.timeoutInSeconds!);
        options.receiveTimeout = Duration(seconds: context.timeoutInSeconds!);
      }

      final downloadUrl = context?.downloadUrl ?? downloadStatus.downloadUrl;

      try {
        debugPrint('DownloadService: 发起 HTTP GET 请求 - $downloadUrl (start=$start)');
        final response = await _dio.get(
          downloadUrl,
          cancelToken: downloadStatus.getCancelToken(),
          onReceiveProgress: (count, total) {
            downloadStatus.updateDownload(start + count, total + start);
            // 通知栏进度更新
            DownloadNotificationService.instance.onDownloadProgress(
              notifId,
              notifTitle,
              downloadStatus.fileName,
              start + count,
              total + start,
            );
          },
          options: options,
        );
        debugPrint('DownloadService: HTTP 响应已到达, statusCode=${response.statusCode}');

        final statusCode = response.statusCode;
        final isRangeResponse = statusCode == 206;
        final isFullResponse = statusCode == 200;

        debugPrint("下载状态码：$statusCode");

        // 服务器返回 200（不支持 Range），从头开始写入
        if (isFullResponse && start > 0) {
          debugPrint("服务器不支持断点续传（200），从头下载");
          if (await downloadTempFile.exists()) {
            await downloadTempFile.delete();
          }
          start = 0;
        }

        final fileStream =
            downloadTempFile.openWrite(mode: FileMode.writeOnlyAppend);

        try {
          // 使用 await for 顺序写入，天然支持背压
          // 注意：流式下载（responseType: stream）时 onReceiveProgress 不触发，
          // 需在读取循环中手动更新进度
          var received = 0;
          await for (final data in response.data.stream) {
            fileStream.add(data);
            received += data.length as int;
            downloadStatus.updateDownload(start + received, downloadStatus.total + start);
            DownloadNotificationService.instance.onDownloadProgress(
              notifId,
              notifTitle,
              downloadStatus.fileName,
              start + received,
              downloadStatus.total + start,
            );
          }
          debugPrint('DownloadService: 流读取完成, 本次收到 $received 字节');
          await fileStream.close();
          if (isRangeResponse || isFullResponse) {
            downloadTempFile.renameSync(file.path);
            _install(downloadStatus.fileName, downloadStatus.savePath);
            downloadStatus.downloadSuccess();
            DownloadNotificationService.instance
                .onDownloadComplete(notifId);
            // 下载成功（APK）：异步解析并更新真实包名/图标（GitHub 渠道）
            if (file.path.endsWith('.apk')) {
              unawaited(
                ApkInfoService.instance.handleDownloadedApk(
                  appId: downloadStatus.appId,
                  apkPath: file.path,
                ),
              );
            }
            return;
          } else {
            downloadStatus.downloadError();
            DownloadNotificationService.instance.onDownloadError(
              notifId,
              notifTitle,
            );
            return;
          }
        } on DioException catch (e) {
          await fileStream.close();
          if (CancelToken.isCancel(e)) {
            appLog.info("取消下载：$downloadUrl");
            downloadStatus.downloadCanced();
            DownloadNotificationService.instance.onDownloadCancel(notifId);
            return;
          }
          appLog.error("下载异常：$downloadUrl ${e.message}");
        } catch (e) {
          await fileStream.close();
          appLog.error("下载异常：$downloadUrl $e");
        }
      } on DioException catch (e) {
        if (CancelToken.isCancel(e)) {
          appLog.info("取消下载：$downloadUrl");
          downloadStatus.downloadCanced();
          DownloadNotificationService.instance.onDownloadCancel(notifId);
          return;
        }
        appLog.error("下载异常：$downloadUrl ${e.message}");
      } catch (e) {
        appLog.error("下载异常：$downloadUrl $e");
      }

      // 到达这里说明下载失败，尝试重试
      if (attempt < maxRetryCount) {
        attempt++;
        continue;
      }
      downloadStatus.downloadError();
      DownloadNotificationService.instance.onDownloadError(notifId, notifTitle);
      return;
    }
  }

  _install(String fileName, String filePath) {
    if (GetPlatform.isAndroid && fileName.endsWith(".apk")) {
      // 使用 InstallManager 统一安装（Shizuku 静默安装优先，回退系统安装）
      InstallManager.instance.installApk(filePath);
      return true;
    }
    return false;
  }
}
