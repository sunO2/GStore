import 'dart:io';
import 'package:app_installer/app_installer.dart';
import 'package:gstore/http/download/DownloadStatus.dart';
import 'package:gstore/core/core.dart';
import 'package:dio/dio.dart';
import 'package:gstore/http/download/DownloadStatusDataBase.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

final Future<DownloadDatabase> database = downloadStatusDatabase;

class DownloadService extends GetxService {
  StreamSubscription<List<ConnectivityResult>>? _subscription;
  List<ConnectivityResult>? _connectivityResult;
  bool _isVPN = false;

  final Dio _dio;

  DownloadService(this._dio);

  @override
  onInit() async {
    _connectivityResult = await (Connectivity().checkConnectivity());
    _isVPN = _connectivityResult?.contains(ConnectivityResult.vpn) ?? false;
    log("初始化网络: ${_connectivityResult?.map((a) {
          return a.name;
        }).toList().join(",")}");
    _subscription = Connectivity()
        .onConnectivityChanged
        .listen((List<ConnectivityResult> result) {
      _connectivityResult = result;
      _isVPN = result.contains(ConnectivityResult.vpn);
      log("网络变化: ${result.map((a) {
            return a.name;
          }).toList().join(",")}");
      // Received changes in available connectivity types!
    });
    super.onInit();
  }

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
    var downloadStatus = (await (await database)
            .downloadStatusDao
            .getDownloadOfName(fileName, version)) ??
        (await DownloadStatus.create(appid, appName, version, fileName, url,
            downloadSize: downloadSize, saveFileName: saveFileName));
    if (downloadStatus.status == DownloadStatus.DOWNLOAD_SUCCESS &&
        _install(fileName, downloadStatus.savePath)) {
      return downloadStatus;
    }

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

  _install(String fileName, String filePath) {
    if (GetPlatform.isAndroid && fileName.endsWith(".apk")) {
      AppInstaller.installApk(filePath);
      return true;
    }
    return false;
  }

  bool get isVPN => _isVPN;

  @override
  void onClose() {
    _subscription?.cancel();
    super.onClose();
  }
}
