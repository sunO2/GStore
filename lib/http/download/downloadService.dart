import 'package:app_installer/app_installer.dart';
import 'package:gstore/http/download/DownloadStatus.dart';
import 'package:gstore/core/core.dart';
import 'package:dio/dio.dart';

class DownloadService extends GetxService {
  final _downloadManager = <String, DownloadStatus>{};

  final Dio _dio;

  DownloadService(this._dio);

  Future<DownloadStatus> download(String appid, appName, version, url, fileName,
      {int? downloadSize}) async {
    var downloadStatus = _downloadManager[fileName] ??
        (await DownloadStatus.create(appid, appName, version, fileName, url,
            downloadSize: downloadSize));
    if (downloadStatus.status == DownloadStatus.DOWNLOAD_SUCCESS) {
      _install(fileName, downloadStatus.savePath);
      return downloadStatus;
    }
    _dio.download(downloadStatus.downloadUrl, downloadStatus.savePath,
        onReceiveProgress: (count, total) {
      downloadStatus.updateDownload(count, total);
    }).then((response) {
      log("statusCode: ${response.statusCode}   response: $response");
      if (response.statusCode == 200) {
        _install(fileName, downloadStatus.savePath);
        downloadStatus.downloadSuccess();
      } else {
        downloadStatus.downloadError();
      }
    }).catchError((error) {
      downloadStatus.downloadError();
    });
    return downloadStatus;
  }

  _install(String fileName, String filePath) {
    if (GetPlatform.isAndroid && fileName.endsWith(".apk")) {
      AppInstaller.installApk(filePath);
    }
  }
}
