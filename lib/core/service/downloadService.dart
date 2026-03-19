import 'dart:io';
import 'package:app_installer/app_installer.dart';
import 'package:gstore/http/download/DownloadStatus.dart';
import 'package:gstore/core/core.dart';
import 'package:dio/dio.dart';
import 'package:gstore/http/download/DownloadStatusDataBase.dart';
import 'package:gstore/core/download/model/DownloadContext.dart';

final Future<DownloadDatabase> database = downloadStatusDatabase;

class DownloadService extends GetxService {
  final Dio _dio;

  DownloadService(this._dio);

  /// 下载文件
  /// appid 包名
  /// appName 应用名称
  /// version 版本
  /// url 下载地址
  /// fileName 文件名
  /// downloadSize 文件大小
  /// breakPoint 是否支持断点续传
  /// saveName 保存的文件名
  Future<DownloadStatus> download(String appid, appName, version, url, fileName,
      {int? downloadSize, bool breakPoint = true, String? saveFileName}) async {
    // 检查是否正在下载
    if (DownloadStatus.isDownloading(appid, version, fileName)) {
      log("文件正在下载中，跳过重复下载: $fileName");
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
        (await DownloadStatus.create(appid, appName, version, fileName, url,
            downloadSize: downloadSize, saveFileName: saveFileName));
    if (downloadStatus.status == DownloadStatus.DOWNLOAD_SUCCESS &&
        _install(fileName, downloadStatus.savePath)) {
      return downloadStatus;
    }

    // 标记为正在下载
    downloadStatus.markAsDownloading();

    final file = File(downloadStatus.savePath);
    var downloadTempFile = File("${file.path}.temp");
    // 确保目录存在
    await file.parent.create(recursive: true);
    int start = 0;

    // 获取已下载的文件大小
    if (breakPoint && await downloadTempFile.exists()) {
      start = await downloadTempFile.length();
    }

    final response = await _dio.get(
      downloadStatus.downloadUrl,
      cancelToken: downloadStatus.getCancelToken(),
      onReceiveProgress: (count, total) {
        downloadStatus.updateDownload(start + count, total + start);
      },
      options: Options(
        headers: {'Range': 'bytes=$start-'},
        responseType: ResponseType.stream,
      ),
    );
    final fileStream =
        downloadTempFile.openWrite(mode: FileMode.writeOnlyAppend);
    bool isClosed = false;
    log("下载状态码：${response.statusCode}");

    response.data.stream.listen((data) {
      fileStream.add(data);
    }, onDone: () async {
      if (!isClosed) {
        isClosed = true;
        await fileStream.close();
        if (response.statusCode == 200 || response.statusCode == 206) {
          downloadTempFile.renameSync(file.path);
          _install(fileName, downloadStatus.savePath);
          downloadStatus.downloadSuccess();
        } else {
          downloadStatus.downloadError();
        }
      }
    }, onError: (error) async {
      if (!isClosed) {
        isClosed = true;
        await fileStream.close();
        if (error is DioException) {
          if (CancelToken.isCancel(error)) {
            log("取消下载：${downloadStatus.downloadUrl}");
            downloadStatus.downloadCanced();
            return;
          }
        }
        log("错误：${downloadStatus.downloadUrl} ${error.message}");
        downloadStatus.downloadError();
      }
    });
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
      log("文件正在下载中，跳过重复下载: $fileName");
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

    final file = File(downloadStatus.savePath);
    var downloadTempFile = File("${file.path}.temp");
    // 确保目录存在
    await file.parent.create(recursive: true);
    int start = 0;

    // 获取已下载的文件大小
    if (breakPoint && await downloadTempFile.exists()) {
      start = await downloadTempFile.length();
    }

    // 构建请求头
    final headers = <String, String>{'Range': 'bytes=$start-'};
    if (context.hasCustomHeaders) {
      headers.addAll(context.headers!);
    }

    // 配置请求选项
    final options = Options(
      headers: headers,
      responseType: ResponseType.stream,
    );

    // 设置超时
    if (context.timeoutInSeconds != null) {
      options.sendTimeout = Duration(seconds: context.timeoutInSeconds!);
      options.receiveTimeout = Duration(seconds: context.timeoutInSeconds!);
    }

    final response = await _dio.get(
      context.downloadUrl,
      cancelToken: downloadStatus.getCancelToken(),
      onReceiveProgress: (count, total) {
        downloadStatus.updateDownload(start + count, total + start);
      },
      options: options,
    );

    final fileStream =
        downloadTempFile.openWrite(mode: FileMode.writeOnlyAppend);
    bool isClosed = false;
    log("下载状态码：${response.statusCode}");

    response.data.stream.listen((data) {
      fileStream.add(data);
    }, onDone: () async {
      if (!isClosed) {
        isClosed = true;
        await fileStream.close();
        if (response.statusCode == 200 || response.statusCode == 206) {
          downloadTempFile.renameSync(file.path);
          _install(fileName, downloadStatus.savePath);
          downloadStatus.downloadSuccess();
        } else {
          downloadStatus.downloadError();
        }
      }
    }, onError: (error) async {
      if (!isClosed) {
        isClosed = true;
        await fileStream.close();
        if (error is DioException) {
          if (CancelToken.isCancel(error)) {
            log("取消下载：${context.downloadUrl}");
            downloadStatus.downloadCanced();
            return;
          }
        }
        log("错误：${context.downloadUrl} ${error.message}");
        downloadStatus.downloadError();
      }
    });

    return downloadStatus;
  }

  _install(String fileName, String filePath) {
    if (GetPlatform.isAndroid && fileName.endsWith(".apk")) {
      AppInstaller.installApk(filePath);
      return true;
    }
    return false;
  }
}
