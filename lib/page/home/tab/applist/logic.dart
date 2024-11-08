import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:gstore/db/apps/AppInfoDatabase.dart';
import 'package:gstore/http/download/DownloadStatus.dart';
import 'package:gstore/http/download/downloadService.dart';
import 'package:gstore/core/core.dart';

import 'state.dart';

import 'package:path_provider/path_provider.dart';

class ApplistLogic extends GetxController with GithubRequestMix {
  final ApplistState state = ApplistState();
  AppInfoDatabase? appDatabase;

  @override
  void onReady() async {
    super.onReady();
    var path = await getDownloadsDirectory();
    var dbFile = File("${path?.path}/apps.db");
    var exists = await dbFile.exists();
    if (!exists) {
      var bytes = await rootBundle.load("assets/app/db/apps.db");
      ByteBuffer buffer = bytes.buffer;
      await dbFile.writeAsBytes(
          buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes));
    }
    await refreshDataOfDB();
    checkUpdata();
  }

  Future<void> checkUpdata() async {
    var task = await githubApi
        .releases("sunO2", "GStore-Repositorys", 1, cancelToken)
        .catchError((e) {
      log("$e");
    });
    List<dynamic> gstoreRepositorys = jsonDecode(task);
    dynamic release =
        (gstoreRepositorys.isNotEmpty) ? gstoreRepositorys[0] ?? {} : {};
    var version = release["name"];
    if (version != state.version) {
      var downloadStatus = await Get.showOverlay(
        asyncFunction: () async {
          final completer = Completer<int>();
          final cancel = Completer<int>();
          var assets = release["assets"][0];
          var status = await Get.find<DownloadService>().download(
              assets["browser_download_url"], assets["name"],
              downloadSize: assets["size"]);
          var sub = status.observer.listen((dStatus) {
            if (dStatus.status == DownloadStatus.DOWNLOAD_SUCCESS ||
                dStatus.status == DownloadStatus.DOWNLOAD_ERROR) {
              completer.complete(dStatus.status);
              cancel.complete(dStatus.status);
            } else if (dStatus.status == DownloadStatus.DOWNLOAD_LOADING) {
              log("数据库更新进度 ${((dStatus.count / dStatus.total) * 100).toInt()}");
            }
          });
          return completer.future.whenComplete(() {
            sub.cancel();
          });
        },
        loadingWidget: Center(
          child: SizedBox(
            width: 120,
            height: 120,
            child: Container(
              decoration: const BoxDecoration(
                  color: Color.fromARGB(126, 0, 0, 0),
                  borderRadius: BorderRadius.all(Radius.circular(16))),
              child: const Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CupertinoActivityIndicator(
                    color: Color.fromARGB(255, 244, 244, 244),
                    radius: 18.0,
                  ),
                  SizedBox(
                    height: 16,
                  ),
                  Text("数据更新中... ",
                      style: TextStyle(
                          color: Color.fromARGB(255, 215, 215, 215),
                          fontWeight: FontWeight.bold)),
                ],
              ),
            ),
          ),
        ),
        opacity: .0,
      );
      if (downloadStatus == DownloadStatus.DOWNLOAD_SUCCESS) {
        refreshDataOfDB();
      }
    }
  }

  refreshDataOfDB() async {
    appDatabase?.close();
    log("加载数据库数据： ${state.version}");
    appDatabase = await appInfoDatabase;
    state.apps = await appDatabase!.dao
        .getAllApps()
        .catchError((error) => List<AppInfo>.empty());
    var config = await appDatabase!.dao.getVersion();
    state.version = config?.version ?? "";
    log("数据库数据刷新： ${state.version}");
    update();
  }

  //搜索页面
  void search() {
    Get.toNamed(AppRoute.search);
  }

  @override
  void onClose() {
    appDatabase?.close();
    super.onClose();
  }
}
