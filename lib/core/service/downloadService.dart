import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:gstore/http/download/DownloadStatus.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/config/config_manager.dart';
import 'package:gstore/core/config/providers/download_config_provider.dart';
import 'package:gstore/core/module/interfaces/service_interfaces.dart';
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

class DownloadService extends GetxService
    implements IDownloadService {
  final Dio _dio;

  /// 最大并发下载数
  static const int maxConcurrentDownloads = 3;

  /// 失败重试次数
  static const int maxRetryCount = 3;

  final DownloadSemaphore _semaphore =
      DownloadSemaphore(maxConcurrentDownloads);

  /// 是否启用多段下载（内存缓存，配置变化时由 ConfigService 事件更新）
  bool _multiSegmentEnabled = true;

  /// 多段下载开关的订阅
  StreamSubscription? _multiSegmentSub;

  DownloadService(this._dio);

  @override
  void onInit() {
    super.onInit();
    // 订阅 ConfigService：download_config 变化 → 主动更新缓存开关
    try {
      _multiSegmentSub =
          ConfigService.instance.watch(ConfigKeys.downloadConfig).listen(
        (event) async {
          final v = event.newValue;
          if (v is Map<String, dynamic>) {
            try {
              _multiSegmentEnabled =
                  DownloadConfig.fromJson(v).multiSegmentEnabled;
            } catch (_) {}
          } else if (v is bool) {
            _multiSegmentEnabled = v;
          }
        },
      );
    } catch (e) {
      appLog.error('DownloadService: 订阅下载配置失败 - $e');
    }
  }

  @override
  void onClose() {
    _multiSegmentSub?.cancel();
    super.onClose();
  }
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
    // 检查是否正在下载（强制重新下载时跳过防重检查，允许重置状态从头下载）
    if (!forceDownload && DownloadStatus.isDownloading(appid, version, fileName)) {
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

    // 强制重新下载：无论当前状态（含下载中）都重置并从头下载。
    // 若旧任务正在下载，先取消其网络请求/令牌，避免文件写入冲突。
    if (forceDownload) {
      debugPrint('DownloadService: 强制重新下载，重置旧任务状态');
      if (DownloadStatus.isDownloading(appid, version, fileName)) {
        downloadStatus.cancelDownload();
        downloadStatus.markAsCompleted();
        debugPrint('DownloadService: 已取消旧下载任务（下载中 → 重置）');
      }
      // 清除旧的临时文件，从头下载
      final tempFile = File("${downloadStatus.savePath}.temp");
      if (await tempFile.exists()) {
        await tempFile.delete();
      }
      // 重置进度与状态为就绪（确保从 0 开始）
      downloadStatus.count = 0;
      downloadStatus.status = DownloadStatus.DOWNLOAD_READY;
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
  @override
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
    // 多段下载调度：根据配置、文件大小决定是否使用多段
    final notifId = downloadStatus.id ?? downloadStatus.appId.hashCode;
    final notifTitle = downloadStatus.appName.isNotEmpty
        ? downloadStatus.appName
        : downloadStatus.appId;

    // 通知栏进度（下载开始）
    DownloadNotificationService.instance.onDownloadStart(
      notifId,
      notifTitle,
      downloadStatus.fileName,
    );

    // 读取多段下载配置
    final useMultiSegment = await _shouldUseMultiSegment(downloadStatus, breakPoint);

    if (useMultiSegment) {
      appLog.info('DownloadService: 使用多段下载 - ${downloadStatus.fileName} (${downloadStatus.total} B)');
      await _performDownloadMultiSegment(
        downloadStatus,
        context: context,
        notifId: notifId,
        notifTitle: notifTitle,
      );
      return;
    }

    // 单段（原逻辑）
    await _performDownloadSingle(
      downloadStatus,
      context: context,
      breakPoint: breakPoint,
      notifId: notifId,
      notifTitle: notifTitle,
    );
  }

  /// 判断是否使用多段下载
  /// 需同时满足：
  /// 1. 配置开关开启
  /// 2. 支持断点续传
  /// 3. 文件大小超过最小阈值（>= 2MB）
  Future<bool> _shouldUseMultiSegment(
    DownloadStatus downloadStatus,
    bool breakPoint,
  ) async {
    try {
      if (!breakPoint) return false;
      // 读取开关（内存缓存优先；首次从配置读取）
      var enabled = _multiSegmentEnabled;
      if (!enabled) {
        try {
          final provider = ConfigManager.instance.providers['download_config'];
          if (provider is DownloadConfigProvider) {
            enabled = await provider.isMultiSegmentEnabled();
            _multiSegmentEnabled = enabled;
          }
        } catch (e) {
          appLog.error('DownloadService: 读取多段开关失败（默认开启）- $e');
        }
      }
      if (!enabled) return false;

      // 文件大小需已知且 >= 2MB
      final total = downloadStatus.total;
      if (total < SegmentPlanner.minMultiSegmentSize) return false;

      return true;
    } catch (e) {
      appLog.error('DownloadService: 判断多段失败（回退单段）- $e');
      return false;
    }
  }

  /// 多段并行下载实现
  Future<void> _performDownloadMultiSegment(
    DownloadStatus downloadStatus, {
    DownloadContext? context,
    required int notifId,
    required String notifTitle,
  }) async {
    final url = context?.downloadUrl ?? downloadStatus.downloadUrl;
    final file = File(downloadStatus.savePath);
    await file.parent.create(recursive: true);

    int attempt = 0;
    while (attempt <= maxRetryCount) {
      if (attempt > 0) {
        appLog.info("重试多段下载 (${attempt}/$maxRetryCount): ${downloadStatus.fileName}");
        await Future.delayed(Duration(seconds: attempt * 2));
      }

      // 规划分段（探测 Range + 自适应段数）
      final plan = await SegmentPlanner.plan(
        url: url,
        totalBytes: downloadStatus.total,
        supportBreakpoint: true,
        dio: _dio,
        cancelToken: downloadStatus.getSegmentCancelToken(0),
        headers: context?.headers,
      );

      // 探测失败或文件不支持多段 → 回退单段
      if (plan == null ||
          !plan.supportsRange ||
          !plan.isMultiSegment) {
        debugPrint('DownloadService: 服务器不支持多段，回退单连接');
        await _performDownloadSingle(
          downloadStatus,
          context: context,
          breakPoint: true,
          notifId: notifId,
          notifTitle: notifTitle,
        );
        return;
      }

      // 多段下载
      final downloader = SegmentDownloader(_dio);
      final result = await downloader.downloadSegments(
        plan: plan,
        status: downloadStatus,
        context: context,
        onProgress: (count, total) {
          // 通知栏进度（多段进度由 SegmentDownloader 内部调用 status.updateDownload）
          DownloadNotificationService.instance.onDownloadProgress(
            notifId,
            notifTitle,
            downloadStatus.fileName,
            count,
            total,
          );
        },
      );

      if (result.cancelled) {
        appLog.info("取消下载：$url");
        downloadStatus.downloadCanced();
        DownloadNotificationService.instance.onDownloadCancel(notifId);
        return;
      }

      if (!result.success) {
        // 服务器不支持分段：直接回退单段（不重试多段）
        if (result.fallback) {
          appLog.info("服务器不支持多段，回退单连接下载");
          await _performDownloadSingle(
            downloadStatus,
            context: context,
            breakPoint: true,
            notifId: notifId,
            notifTitle: notifTitle,
          );
          return;
        }

        appLog.error("多段下载失败：${result.errorMessage}");
        // 段级已重试过，这里做任务级重试
        if (attempt < maxRetryCount) {
          attempt++;
          continue;
        }
        // 清理不完整的 part 文件
        await SegmentMerger.cleanupParts(
          downloadStatus.savePath,
          plan.segmentCount,
        );
        downloadStatus.downloadError();
        DownloadNotificationService.instance.onDownloadError(notifId, notifTitle);
        return;
      }

      // 全部段下载成功 → 合并
      final merged = await SegmentMerger.merge(
        savePath: downloadStatus.savePath,
        segmentCount: plan.segmentCount,
      );
      if (!merged) {
        if (attempt < maxRetryCount) {
          attempt++;
          continue;
        }
        downloadStatus.downloadError();
        DownloadNotificationService.instance.onDownloadError(notifId, notifTitle);
        return;
      }

      // 合并成功
      _install(downloadStatus.fileName, downloadStatus.savePath);
      downloadStatus.downloadSuccess();
      DownloadNotificationService.instance.onDownloadComplete(notifId);
      _afterDownloadInstalled(downloadStatus);

      // 下载成功（APK）：异步解析并更新真实包名/图标
      if (file.path.endsWith('.apk')) {
        unawaited(
          ApkInfoService.instance.handleDownloadedApk(
            appId: downloadStatus.appId,
            apkPath: file.path,
          ),
        );
      }
      return;
    }

    // 全部重试耗尽
    downloadStatus.downloadError();
    DownloadNotificationService.instance.onDownloadError(notifId, notifTitle);
  }

  /// 单连接下载实现（原逻辑）
  Future<void> _performDownloadSingle(
    DownloadStatus downloadStatus, {
    DownloadContext? context,
    bool breakPoint = true,
    required int notifId,
    required String notifTitle,
  }) async {
    final file = File(downloadStatus.savePath);
    var downloadTempFile = File("${file.path}.temp");
    // 确保目录存在
    await file.parent.create(recursive: true);

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
            _afterDownloadInstalled(downloadStatus);
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
      // 安装模块下线 → 注册表取不到服务，短路不安装
      final manager = ModuleManager.instance.get<InstallManager>();
      if (manager == null) return false;
      // 使用 InstallManager 统一安装（Shizuku 静默安装优先，回退系统安装）
      manager.installApk(filePath);
      return true;
    }
    return false;
  }

  /// 下载安装完成后刷新更新状态（从可更新列表移除已更新应用）
  /// 后台异步，不阻塞下载流程
  void _afterDownloadInstalled(DownloadStatus status) {
    try {
      final appId = status.appId;
      if (appId.isEmpty) return;
      unawaited(UpdateManagerService.instance.markUpdated(appId));
    } catch (e) {
      // 更新状态刷新失败不影响下载本身
    }
  }
}
