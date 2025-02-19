import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/utils/unit.dart';
import 'package:gstore/db/apps/AppInfoDatabase.dart';
import 'package:gstore/http/download/DownloadStatus.dart';
import 'package:gstore/http/download/downloadService.dart';
import 'package:gstore/http/github/github_client.dart';
import 'package:path_provider/path_provider.dart';
import 'package:gstore/db/apps/AppInfoDatabase.dart' as db;

class DBRepository {
  final String target;
  final String user;
  final String repositroy;
  final AppInfoDatabase db;

  DBRepository(this.target, this.user, this.repositroy, this.db);

  copyWith(
      {String? target, String? user, String? repositroy, AppInfoDatabase? db}) {
    return DBRepository(target ?? this.target, user ?? this.user,
        repositroy ?? this.repositroy, db ?? this.db);
  }
}

class DbManager extends GetxService {
  final githubApi = Get.find<GithubRestClient>();
  var dbRepositroies = <String, DBRepository>{};

  Future<DbManager> init() async {
    var path = await getDownloadsDirectory();
    var dbFile = File("${path?.path}/gstore/apps.db");
    await dbFile.parent.create(recursive: true);
    if (!(await dbFile.exists())) {
      var bytes = await rootBundle.load("assets/app/db/apps.db");
      ByteBuffer buffer = bytes.buffer;
      await dbFile.writeAsBytes(
          buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes));
    }
    dbRepositroies["gstore"] = (DBRepository("gstore", "sunO2",
        "GStore-Repositorys", await db.Builder("gstore/apps.db").build()));
    return this;
  }

  DBRepository _getDB(String name) {
    return dbRepositroies[name]!;
  }

  Future<void> downloadDB() async {
    return;
  }

  Future<void> addDBRepositroy(DBRepository dbRepositroy) async {
    return;
  }

  /// 检查数据库更新
  Future<int> _checkUpdateDBOfRepositroy(String target) async {
    DBRepository dbRepositroy = dbRepositroies[target]!;
    var dbVersion =
        (await dbRepositroy.db.dao.getVersion())?.version ?? "0.0.0.0";
    var task = await githubApi
        .releases("sunO2", "GStore-Repositorys", 1, CancelToken())
        .catchError((e) {
      log("$e");
    });
    List<dynamic> gstoreRepositorys = jsonDecode(task);
    dynamic release =
        (gstoreRepositorys.isNotEmpty) ? gstoreRepositorys[0] ?? {} : {};
    var version = release["name"];
    if (compareVersion(dbVersion, version) == 1) {
      return Get.showOverlay(
        asyncFunction: () async {
          final completer = Completer<DownloadStatus>();
          final cancel = Completer<DownloadStatus>();
          var assets = release["assets"][0];
          var status = await Get.find<DownloadService>().download(
              "com.sunO2.gstore.db",
              "GStore.db",
              version,
              "$proxy${assets["browser_download_url"]}",
              assets["name"],
              downloadSize: assets["size"],
              saveFileName: "gstore/apps.db");
          var sub = status.observer.listen((dStatus) async {
            if (dStatus.status == DownloadStatus.DOWNLOAD_SUCCESS ||
                dStatus.status == DownloadStatus.DOWNLOAD_ERROR) {
              completer.complete(dStatus);
              cancel.complete(dStatus);
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
      ).then((value) async {
        if (value.status == DownloadStatus.DOWNLOAD_SUCCESS) {
          await dbRepositroy.db.close();
          dbRepositroies[target] = dbRepositroy.copyWith(
              db: await db.Builder(
                      "${dbRepositroy.target}/${value.saveFileName}")
                  .build());
        }
        return value.status;
      });
    }
    return -2;
  }
}

extension DBRepositoryExtension on String {
  DBRepository get repoDB => Get.find<DbManager>()._getDB(this);
  Future<int> checkUpdate() =>
      Get.find<DbManager>()._checkUpdateDBOfRepositroy(this);
}
