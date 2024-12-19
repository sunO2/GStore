import 'dart:ffi';

import 'package:dio/dio.dart';
import 'package:floor/floor.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/http/download/DownloadStatusDataBase.dart';
import 'package:gstore/http/download/downloadService.dart';
import 'dart:async';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

final Map<String, StreamController<DownloadStatus>> _streamManager = {};

@entity
class DownloadStatus {
  static const int DOWNLOAD_ERROR = -1;

  /// 准备下载
  static const int DOWNLOAD_READY = 1;

  /// 下载中
  static const int DOWNLOAD_LOADING = 2;

  /// 下载结束
  static const int DOWNLOAD_SUCCESS = 3;

  @ignore
  late StreamController<DownloadStatus> _counterController;

  @PrimaryKey(autoGenerate: true)
  int? id;
  final String appId;
  final String appName;
  final String version;
  final String fileName;
  final String downloadUrl;
  final String savePath;
  int createTime = 0;
  int total = 0;
  int count = 0;
  int status = DOWNLOAD_READY;

  DownloadStatus(this.appId, this.appName, this.version, this.fileName,
      this.downloadUrl, this.savePath,
      {this.total = 0,
      this.count = 0,
      this.status = DOWNLOAD_READY,
      this.id,
      this.createTime = 0}) {
    var stream = _streamManager[fileName];
    if (null == stream) {
      _counterController = StreamController<DownloadStatus>.broadcast();
      _streamManager[fileName] = _counterController;
    } else {
      _counterController = stream;
    }
  }

  @override
  String toString() {
    return '''DownloadStatus{
  id: $id,
  appId: $appId, 
  version: $version,
  fileName: $fileName, 
  total: $total, 
  count: $count, 
  status: $status,
  downloadUrl: $downloadUrl,
  savePath: $savePath,
  crewateTime: $createTime,
}''';
  }

  void downloadError() async {
    status = DOWNLOAD_ERROR;
    _counterController.sink.add(this);
    await (await database).downloadStatusDao.updateDownload(this);
  }

  void downloadSuccess() async {
    count = total;
    status = DOWNLOAD_SUCCESS;
    _counterController.sink.add(this);
    await (await database).downloadStatusDao.updateDownload(this);
  }

  void updateDownload(int count, int total) async {
    this.count = count;
    this.total = total;
    status = DOWNLOAD_LOADING;
    await (await database).downloadStatusDao.updateDownload(this);
    _counterController.sink.add(this);
  }

  Stream<DownloadStatus> get observer => _counterController.stream;

  static Future<DownloadStatus> create(
      String appId, appName, version, name, String downloadUrl,
      {int? downloadSize}) async {
    var path = await getDownloadsDirectory();
    if (null == path) throw Exception("保存路径获取失败");
    var savePath = "${path.path}/$name";

    if (!downloadUrl.startsWith(getProxy())) {
      downloadUrl = "${getProxy()}$downloadUrl";
    }

    var status =
        DownloadStatus(appId, appName, version, name, downloadUrl, savePath);
    status.total = downloadSize ?? 0;

    final item = await (await database)
        .downloadStatusDao
        .getDownloadOfName(name, version);
    if (null == item) {
      status.createTime = DateTime.now().millisecondsSinceEpoch;
      int id = await (await database).downloadStatusDao.insertPerson(status);
      status.id = id;
    }

    var saveFile = File(savePath);
    if (await saveFile.exists()) {
      status.status = DownloadStatus.DOWNLOAD_LOADING;
      var length = await saveFile.length();
      if (length == (downloadSize ?? 0)) {
        status.status = DownloadStatus.DOWNLOAD_SUCCESS;
        status.count = length;
      }
    }

    return status;
  }
}
