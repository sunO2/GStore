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
  /// - 否则落到系统下载目录（取不到时退回应用文档目录）下的 [fileName]
  ///
  /// [downloadsDirProvider] / [docsDirProvider] 是**仅测试使用**的注入接缝：
  /// 传入时替代对应的 path_provider 调用，不传时行为与原先完全一致（仍走
  /// path_provider），因此生产路径不受影响。
  static Future<String> resolveSavePath({
    String? saveFileName,
    required String fileName,
    Future<Directory?> Function()? downloadsDirProvider,
    Future<Directory> Function()? docsDirProvider,
  }) async {
    if (saveFileName != null && saveFileName.startsWith('/')) {
      return saveFileName;
    }
    final dir = await (downloadsDirProvider ?? getDownloadsDirectory)();
    return '${dir?.path ?? (await (docsDirProvider ?? getApplicationDocumentsDirectory)()).path}/$fileName';
  }
}
