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
  static Future<String> resolveSavePath({
    String? saveFileName,
    required String fileName,
  }) async {
    if (saveFileName != null && saveFileName.startsWith('/')) {
      return saveFileName;
    }
    final dir = await getDownloadsDirectory();
    return '${dir?.path ?? (await getApplicationDocumentsDirectory()).path}/$fileName';
  }
}
