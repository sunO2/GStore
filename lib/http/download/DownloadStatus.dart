import 'package:dio/dio.dart';
import 'package:floor/floor.dart';
import 'package:flutter/foundation.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/service/downloadService.dart';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

final Map<String, StreamController<DownloadStatus>> _streamManager = {};
// 取消下载按钮
final Map<String, CancelToken> _cancelTokens = {};
// 正在下载的文件列表（用于防止重复下载）
final Set<String> _downloadingFiles = {};
// 数据库更新节流控制（避免频繁更新数据库）
final Map<String, DateTime> _lastUpdateTime = {};
// 节流间隔（毫秒）
const _updateThrottleMs = 500;

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
      _cancelTokens[_downloadTag] = token;
    }
    return token;
  }

  /// 检查文件是否正在下载
  static bool isDownloading(String appid, String version, String fileName) {
    final tag = "$appid-$version-$fileName";
    return _downloadingFiles.contains(tag);
  }

  /// 标记文件开始下载
  void markAsDownloading() {
    _downloadingFiles.add(_downloadTag);
  }

  /// 标记文件下载完成（成功、取消或失败）
  void markAsCompleted() {
    _downloadingFiles.remove(_downloadTag);
  }

  /// 获取所有正在下载的文件标签
  static Set<String> getDownloadingFiles() {
    return Set.from(_downloadingFiles);
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
    var token = _cancelTokens[_downloadTag];
    if (null != token) {
      token.cancel();
      _cancelTokens.remove(_downloadTag);
    }
  }

  void downloadCanced() async {
    status = DOWNLOAD_READY;
    markAsCompleted();
    _cleanupAfterComplete();
    _counterController.sink.add(this);
    _lastUpdateTime.remove(_downloadTag);  // 清理节流记录
    await (await database).downloadStatusDao.updateDownload(this);
  }

  void downloadError() async {
    status = DOWNLOAD_ERROR;
    markAsCompleted();
    _cleanupAfterComplete();
    _counterController.sink.add(this);
    _lastUpdateTime.remove(_downloadTag);  // 清理节流记录
    await (await database).downloadStatusDao.updateDownload(this);
  }

  void downloadSuccess() async {
    count = total;
    status = DOWNLOAD_SUCCESS;
    markAsCompleted();
    _cleanupAfterComplete();
    _counterController.sink.add(this);
    _lastUpdateTime.remove(_downloadTag);  // 清理节流记录
    await (await database).downloadStatusDao.updateDownload(this);
  }

  /// 清理下载完成后的资源
  /// 释放取消令牌，避免内存泄漏
  void _cleanupAfterComplete() {
    _cancelTokens.remove(_downloadTag);
  }

  /// 释放所有资源（删除记录时调用）
  /// 从全局映射中移除，避免内存泄漏
  /// 注意：不主动关闭 StreamController，避免 UI 仍在监听时报错
  void dispose() {
    _cancelTokens.remove(_downloadTag);
    _lastUpdateTime.remove(_downloadTag);
    markAsCompleted();
    _streamManager.remove(_downloadTag);
  }

  void updateDownload(int count, int total) async {
    this.count = count;
    this.total = total;
    status = DOWNLOAD_LOADING;

    // 始终更新 Stream（UI 需要实时进度）
    _counterController.sink.add(this);

    // 节流：只在超过节流间隔时才更新数据库
    final now = DateTime.now();
    final lastUpdate = _lastUpdateTime[_downloadTag];
    final shouldUpdateDb = lastUpdate == null ||
        now.difference(lastUpdate).inMilliseconds >= _updateThrottleMs;

    if (shouldUpdateDb) {
      _lastUpdateTime[_downloadTag] = now;
      await (await database).downloadStatusDao.updateDownload(this);
    }
  }

  Stream<DownloadStatus> get observer => _counterController.stream;

  /// 检查 URL 是否需要代理
  /// 仅 GitHub 相关域名需要代理加速（国内访问慢）
  static bool _needsProxy(String url) {
    return url.startsWith('https://github.com/') ||
        url.startsWith('https://raw.githubusercontent.com/') ||
        url.startsWith('https://api.github.com/') ||
        url.startsWith('https://objects.githubusercontent.com/') ||
        url.startsWith('http://github.com/');
  }

  static Future<DownloadStatus> create(
      String appId, appName, version, name, String downloadUrl,
      {int? downloadSize, String? saveFileName}) async {
    appLog.info('DownloadStatus.create 开始: name=$name version=$version');
    String savePath;
    // 若 saveFileName 是绝对路径（用于数据库等需要固定位置的文件），直接使用
    if (saveFileName != null && saveFileName.startsWith('/')) {
      savePath = saveFileName;
      debugPrint('DownloadStatus.create: 使用绝对路径 savePath = $savePath');
    } else {
      var path = await getDownloadsDirectory();
      debugPrint('DownloadStatus.create: 获取下载目录 = ${path?.path}');
      if (null == path) throw Exception("保存路径获取失败");
      savePath = "${path.path}/${saveFileName ?? "$appId-$version-$name"}";
      debugPrint('DownloadStatus.create: savePath = $savePath');
    }

    // 仅对 GitHub 相关 URL 应用代理，避免破坏 vivo/F-Droid 等渠道的下载链接
    if (_needsProxy(downloadUrl)) {
      final proxy = getProxy();
      if (proxy.isNotEmpty && !downloadUrl.startsWith(proxy)) {
        downloadUrl = "$proxy$downloadUrl";
        debugPrint('DownloadStatus.create: 应用代理 - $downloadUrl');
      }
    }
    var status =
        DownloadStatus(appId, appName, version, name, downloadUrl, savePath);
    status.total = downloadSize ?? 0;

    final item = await (await database)
        .downloadStatusDao
        .getDownloadOfName(name, version);
    debugPrint('DownloadStatus.create: 查重结果 = ${item != null}');
    if (null == item) {
      status.createTime = DateTime.now().millisecondsSinceEpoch;
      int id = await (await database).downloadStatusDao.insertPerson(status);
      status.id = id;
      debugPrint('DownloadStatus.create: 已插入下载记录 id=$id');
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
