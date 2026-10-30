import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// 下载落盘路径的**唯一**解析规则。
///
/// 必须被所有下载实现共用：换内核（Dart / Rust）绝不能让文件落到不同目录，
/// 否则安装流程和用户都找不到文件——这是"看不见文件"这类问题的根因。
class DownloadPaths {
  DownloadPaths._();

  /// 解析最终落盘路径。
  ///
  /// - [saveFileName] 是**绝对路径**时直接采用（调用方显式指定）
  /// - 否则落在**应用私有 `files/` 目录**（`getApplicationSupportDirectory()`，
  ///   即 `/data/user/0/<pkg>/files`）下的 [fileName]
  ///
  /// 为什么必须落在 `files/`：Android 侧 `res/xml/file_paths.xml` 只暴露了
  /// `<files-path path="."/>`（= `/data/user/0/<pkg>/files`）、
  /// `<external-files-path path="downloads"/>` 和 `<external-path path="."/>`。
  /// FileProvider 的根目录必须包含 APK，否则 `FileProvider.getUriForFile` 会
  /// 抛异常；而 `app_installer` 的 Dart 封装是 fire-and-forget（`invokeMethod`
  /// 未 `await`），异常被吞掉 → 我们仍报告"已发起安装"，系统安装界面却永远
  /// 不出现，90 秒后只能超时。旧默认值 `getDownloadsDirectory()`
  /// （`Android/data/<pkg>/files/downloads`，本机还会返回 null）与
  /// `getApplicationDocumentsDirectory()`（`app_flutter`）都不在 FileProvider
  /// 覆盖范围内，因此**刻意不再使用**。
  ///
  /// [downloadsDirProvider] / [docsDirProvider] 是**仅测试使用**的注入接缝：
  /// 传入时仍按原优先级生效（下载目录优先，取不到时退回文档目录），
  /// `test/fixtures/download_path_cases.json` 依赖该行为；不传时生产环境直接
  /// 使用 `getApplicationSupportDirectory()`，其 `files/` 目录被 FileProvider
  /// 覆盖。
  static Future<String> resolveSavePath({
    String? saveFileName,
    required String fileName,
    Future<Directory?> Function()? downloadsDirProvider,
    Future<Directory> Function()? docsDirProvider,
  }) async {
    if (saveFileName != null && saveFileName.startsWith('/')) {
      return saveFileName;
    }
    final injectedDownloadDir =
        downloadsDirProvider == null ? null : await downloadsDirProvider();
    final dir = injectedDownloadDir ??
        await (docsDirProvider ?? getApplicationSupportDirectory)();
    return '${dir.path}/$fileName';
  }
}
