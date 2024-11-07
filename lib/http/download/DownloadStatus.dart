import 'package:floor/floor.dart';
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
  int total = 0;
  int count = 0;
  int status = DOWNLOAD_READY;
  @primaryKey
  final String name;
  final String downloadUrl;
  final String savePath;
  DownloadStatus(this.name, this.downloadUrl, this.savePath) {
    var stream = _streamManager[name];
    if (null == stream) {
      _counterController = StreamController<DownloadStatus>.broadcast();
      _streamManager[name] = _counterController;
    } else {
      _counterController = stream;
    }
  }

  @override
  String toString() {
    return 'DownloadStatus{total: $total, count: $count, status: $status, name: $name, downloadUrl: $downloadUrl, savePath: $savePath}';
  }

  void downloadError() {
    status = DOWNLOAD_ERROR;
    _counterController.sink.add(this);
  }

  void downloadSuccess() {
    count = total;
    status = DOWNLOAD_SUCCESS;
    _counterController.sink.add(this);
  }

  void updateDownload(int count, int total) async {
    this.count = count;
    this.total = total;
    status = DOWNLOAD_LOADING;
    _counterController.sink.add(this);
    // final database = await downloadStatusDatabase;
    // database.downloadStatusDao.updateDownload(this);
  }

  Stream<DownloadStatus> get observer => _counterController.stream;

  static Future<DownloadStatus> create(String name, String downloadUrl,
      {int? downloadSize}) async {
    var path = await getDownloadsDirectory();
    if (null == path) throw Exception("保存路径获取失败");
    var savePath = "${path.path}/$name";
    var status = DownloadStatus(name, "https://ghp.ci/$downloadUrl", savePath);
    status.total = downloadSize ?? 0;
    // final database = await downloadStatusDatabase;
    // final item = await database.downloadStatusDao.findPersonById(name).first;
    var saveFile = File(savePath);
    if (await saveFile.exists()) {
      status.status = DownloadStatus.DOWNLOAD_LOADING;
      var length = await saveFile.length();
      if (length == (downloadSize ?? 0)) {
        status.status = DownloadStatus.DOWNLOAD_SUCCESS;
        status.count = length;
      }
    }
    // if (null == item) {
    //   database.downloadStatusDao.insertPerson(status);
    // }
    return status;
  }
}
