import 'package:app_installer/app_installer.dart';
import 'package:gstore/http/download/DownloadStatus.dart';
import 'package:gstore/core/core.dart';
import 'package:dio/dio.dart';
import 'package:gstore/http/download/DownloadStatusDataBase.dart';

final Future<DownloadDatabase> database = downloadStatusDatabase;

class DownloadService extends GetxService {
  final Dio _dio;

  DownloadService(this._dio);

  Future<DownloadStatus> download(String appid, appName, version, url, fileName,
      {int? downloadSize}) async {
    var downloadStatus = (await (await database)
            .downloadStatusDao
            .getDownloadOfName(fileName, version)) ??
        (await DownloadStatus.create(appid, appName, version, fileName, url,
            downloadSize: downloadSize));
    if (downloadStatus.status == DownloadStatus.DOWNLOAD_SUCCESS &&
        _install(fileName, downloadStatus.savePath)) {
      return downloadStatus;
    }

    int start = downloadStatus.count;
    if (fileName.endsWith("apps.db")) start = 0;
    _dio.download(
      downloadStatus.downloadUrl,
      downloadStatus.savePath,
      cancelToken: downloadStatus.getCancelToken(),
      onReceiveProgress: (count, total) {
        downloadStatus.updateDownload(start + count, total);
      },
      options: Options(
        headers: {
          'Range': 'bytes=$start-',
        },
      ),
    ).then((response) {
      log("statusCode: ${response.statusCode}   response: $response");
      if (response.statusCode == 200 || response.statusCode == 206) {
        _install(fileName, downloadStatus.savePath);
        downloadStatus.downloadSuccess();
      } else {
        downloadStatus.downloadError();
      }
    }).catchError((error) {
      if (error is DioException) {
        if (CancelToken.isCancel(error)) {
          log("取消下载：${downloadStatus.downloadUrl}");
          downloadStatus.downloadCanced();
          return;
        }
      }
      log("错误：${downloadStatus.downloadUrl} ${error.message}");
      downloadStatus.downloadError();
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
