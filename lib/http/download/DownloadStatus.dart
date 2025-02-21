import 'package:dio/dio.dart';
import 'package:floor/floor.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/service/downloadService.dart';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

final Map<String, StreamController<DownloadStatus>> _streamManager = {};
// 取消下载按钮
final Map<String, CancelToken> _cancelTokens = {};

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
    /// 默认状态 不为下载成功 则为
    if (status == DOWNLOAD_LOADING) {
      status = DOWNLOAD_READY;
    }
    var stream = _streamManager[_downloadTag];
    if (null == stream) {
      _counterController = StreamController<DownloadStatus>.broadcast();
      _streamManager[_downloadTag] = _counterController;
    } else {
      _counterController = stream;
    }
  }

  get saveFileName {
    return savePath.split("/").last;
  }

  get _downloadTag {
    return "$appId-$version-$fileName";
  }

  CancelToken getCancelToken() {
    var token = _cancelTokens[_downloadTag];
    if (null == token || token.isCancelled) {
      token = CancelToken();
      _cancelTokens[fileName] = token;
    }
    return token;
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

  cancelDownload() {
    var token = _cancelTokens[fileName];
    if (null != token) {
      token.cancel();
      _cancelTokens.remove(fileName);
    }
  }

  void downloadCanced() async {
    status = DOWNLOAD_READY;
    _counterController.sink.add(this);
    await (await database).downloadStatusDao.updateDownload(this);
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
      {int? downloadSize, String? saveFileName}) async {
    var path = await getDownloadsDirectory();
    if (null == path) throw Exception("保存路径获取失败");
    var savePath = "${path.path}/${saveFileName ?? "$appId-$version-$name"}";

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
      // status.status = DownloadStatus.DOWNLOAD_LOADING;
      var length = await saveFile.length();
      if (length == (downloadSize ?? 0)) {
        status.status = DownloadStatus.DOWNLOAD_SUCCESS;
        status.count = length;
      }
    }

    return status;
  }
}
