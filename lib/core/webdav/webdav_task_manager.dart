import 'package:get/get.dart';
import 'package:gstore/core/module/interfaces/service_interfaces.dart';

/// WebDAV 任务管理器（单例）
///
/// 防重复 + 状态管理：
/// - [tryStart] 在已有任务进行中时返回 false（上传/下载互斥）
/// - UI 侧经 Obx 监听 [isUploading]/[isDownloading] 禁用入口按钮
///
/// 状态管理选型：Get Rx（项目 GetX 体系；mine 页按钮需 Obx 监听，
/// 与 GetX 依赖注入/控制器体系一致，改动最小）。
class WebDavTaskManager implements IWebDavTaskManager {
  WebDavTaskManager._internal();

  static WebDavTaskManager? _instance;
  static WebDavTaskManager get instance => _instance ??= WebDavTaskManager._internal();

  final RxBool _isUploading = false.obs;
  final RxBool _isDownloading = false.obs;

  /// 是否正在上传（Obx 可直接监听）
  @override
  bool get isUploading => _isUploading.value;

  /// 是否正在下载（Obx 可直接监听）
  @override
  bool get isDownloading => _isDownloading.value;

  /// 是否有任务进行中
  @override
  bool get isBusy => _isUploading.value || _isDownloading.value;

  /// 尝试开始任务（同类型任务进行中返回 false；上传/下载互不阻塞）
  @override
  bool tryStart(WebDavTaskType type) {
    switch (type) {
      case WebDavTaskType.upload:
        if (_isUploading.value) return false;
        _isUploading.value = true;
      case WebDavTaskType.download:
        if (_isDownloading.value) return false;
        _isDownloading.value = true;
    }
    return true;
  }

  /// 结束任务（复位对应状态）
  @override
  void finish(WebDavTaskType type) {
    switch (type) {
      case WebDavTaskType.upload:
        _isUploading.value = false;
      case WebDavTaskType.download:
        _isDownloading.value = false;
    }
  }
}
