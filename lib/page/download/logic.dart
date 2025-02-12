import 'package:app_installer/app_installer.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/db/apps/AppInfoDatabase.dart';
import 'package:gstore/http/download/DownloadStatus.dart';
import 'package:gstore/http/download/DownloadStatusDataBase.dart';
import 'package:gstore/http/download/downloadService.dart';

import 'state.dart';

class DownloadManagerLogic extends GetxController with GithubRequestMix {
  final DownloadManagerState state = DownloadManagerState();
  final Future<DownloadDatabase> database = downloadStatusDatabase;
  final Future<AppInfoDatabase> appInfoDB = appInfoDatabase;
  final StreamController<List<List<DownloadStatus>>> controller =
      StreamController();

  @override
  void onReady() async {
    var db = await database;
    var downloadList = db.downloadStatusDao.getAllDownload();
    downloadList.listen((items) {
      var map = <String, List<DownloadStatus>>{};
      for (var item in items) {
        var key = "${item.appId}_${item.version}";
        var list = map[key] ??
            () {
              return map[key] = <DownloadStatus>[];
            }();
        list.add(item);
      }
      controller.sink.add(List.from(map.values));
    });
    super.onReady();
  }

  Future<AppInfo?> getAppInfo(String appId) async {
    return (await appInfoDB).dao.getAppInfo(appId);
  }

  void installApp(DownloadStatus downStatus) {
    // 实现安装应用的逻辑
    if (GetPlatform.isAndroid && downStatus.fileName.endsWith(".apk")) {
      AppInstaller.installApk(downStatus.savePath);
    }
  }

  void retryDownload(DownloadStatus downStatus) async {
    // 实现重新下载的逻辑
    downStatus.updateDownload(0, downStatus.total);
    await Get.find<DownloadService>().download(
        downStatus.appId,
        downStatus.appName,
        downStatus.version,
        downStatus.downloadUrl,
        downStatus.fileName,
        downloadSize: downStatus.total);
  }

  void pauseDownload(DownloadStatus downStatus) {
    // 实现暂停下载的逻辑
  }

  void deleteDownload(DownloadStatus downStatus) async {
    // 实现删除下载的逻辑
  }

  @override
  void onClose() async {
    // (await database).close();
    super.onClose();
  }
}
