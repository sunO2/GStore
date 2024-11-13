import 'package:gstore/core/core.dart';
import 'package:gstore/db/apps/AppInfoDatabase.dart';
import 'package:gstore/http/download/DownloadStatus.dart';
import 'package:gstore/http/download/DownloadStatusDataBase.dart';

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
    var downloadList = await db.downloadStatusDao.getAllDownload();
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

  @override
  void onClose() async {
    // (await database).close();
    super.onClose();
  }
}
