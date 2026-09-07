import 'package:gstore/core/module/interfaces/service_interfaces.dart';

/// WebDAV 任务管理器（单例）
///
/// 防重复 + 状态管理：
/// - [tryStart] 在已有任务进行中时返回 false（上传/下载互斥）
/// - UI 侧读取 [isUploading]/[isDownloading] 禁用入口按钮
///
/// 状态：纯同步 bool（无反应式订阅需求；消费方均为普通 getter 读取）。
class WebDavTaskManager implements IWebDavTaskManager {
  WebDavTaskManager._internal();

  static WebDavTaskManager? _instance;
  static WebDavTaskManager get instance => _instance ??= WebDavTaskManager._internal();

  bool _isUploading = false;
  bool _isDownloading = false;

  /// 是否正在上传
  @override
  bool get isUploading => _isUploading;

  /// 是否正在下载
  @override
  bool get isDownloading => _isDownloading;

  /// 是否有任务进行中
  @override
  bool get isBusy => _isUploading || _isDownloading;

  /// 尝试开始任务（同类型任务进行中返回 false；上传/下载互不阻塞）
  @override
  bool tryStart(WebDavTaskType type) {
    switch (type) {
      case WebDavTaskType.upload:
        if (_isUploading) return false;
        _isUploading = true;
      case WebDavTaskType.download:
        if (_isDownloading) return false;
        _isDownloading = true;
    }
    return true;
  }

  /// 结束任务（复位对应状态）
  @override
  void finish(WebDavTaskType type) {
    switch (type) {
      case WebDavTaskType.upload:
        _isUploading = false;
      case WebDavTaskType.download:
        _isDownloading = false;
    }
  }
}
