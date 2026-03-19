import 'package:get/get.dart';

import 'package:gstore/core/core.dart';

/// WebDAV 连接状态
enum WebDavConnectionStatus {
  /// 未配置
  notConfigured,
  /// 连接成功
  connected,
  /// 连接失败
  failed,
  /// 测试中
  testing,
}

/// 恢复模式
enum RestoreMode {
  /// 覆盖模式
  replace,
  /// 合并模式
  merge,
  /// 更新模式
  update,
}

class BackupState {
  /// 是否正在导出
  final RxBool isExporting = false.obs;

  /// 是否正在导入
  final RxBool isImporting = false.obs;

  /// 统计信息
  final Rx<BackupStatistics?> statistics = Rx<BackupStatistics?>(null);

  /// 错误信息
  final RxString errorMessage = ''.obs;

  /// 是否已配置 WebDAV
  final RxBool hasWebDavConfig = false.obs;

  /// 是否正在上传到 WebDAV
  final RxBool isUploadingWebDav = false.obs;

  /// WebDAV 连接状态
  final Rx<WebDavConnectionStatus> webDavStatus = WebDavConnectionStatus.notConfigured.obs;

  /// 是否包含应用配置（导出时）
  final RxBool includeAppConfig = true.obs;

  /// 是否恢复应用配置（导入时）
  final RxBool restoreAppConfig = true.obs;

  /// 恢复模式
  final Rx<RestoreMode> restoreMode = RestoreMode.merge.obs;
}
