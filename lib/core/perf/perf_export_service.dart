/// 性能报告导出/分享的宿主通道封装（`gstore/system_intent`）。
///
/// 复用既有系统意图通道 [MethodChannel]（`gstore/system_intent`，见
/// `install_manager.dart` 与 `MainActivity.kt`），新增两个方法：
/// * `shareText`：`ACTION_SEND`（`text/plain`）分享纯文本；
/// * `shareFile`：`ACTION_SEND` + `FileProvider` Uri 分享文件。
///
/// 平台缺失 / 通道异常一律降级为 `false`，绝不向 UI 抛异常。
/// [shareReport] 提供「先文件、失败退文本」的高层封装，适配 docs 目录未被
/// FileProvider `file_paths` 覆盖的场景。
library;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart' show MethodChannel;

/// 系统意图分享封装（可注入 [MethodChannel] 便于测试）。
class PerfExportService {
  PerfExportService({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(channelName);

  /// 通道名（与 `MainActivity.kt` 的 `CHANNEL` 常量一致）。
  static const String channelName = 'gstore/system_intent';

  /// 生产单例。
  static final PerfExportService instance = PerfExportService();

  final MethodChannel _channel;

  /// 分享纯文本。返回宿主是否成功调起分享面板。
  Future<bool> shareText(String text, {String? subject, String? title}) async {
    if (text.isEmpty) return false;
    try {
      final ok = await _channel.invokeMethod<bool>('shareText', <String, dynamic>{
        'text': text,
        'subject': subject,
        'title': title,
      });
      return ok ?? false;
    } catch (error) {
      debugPrint('[PerfExportService] shareText 失败（降级 false）: $error');
      return false;
    }
  }

  /// 分享文件（经 `FileProvider` Uri）。返回宿主是否成功调起分享面板。
  Future<bool> shareFile(
    String path, {
    String mimeType = 'application/octet-stream',
    String? subject,
    String? title,
  }) async {
    if (path.isEmpty) return false;
    try {
      final ok = await _channel.invokeMethod<bool>('shareFile', <String, dynamic>{
        'path': path,
        'mimeType': mimeType,
        'subject': subject,
        'title': title,
      });
      return ok ?? false;
    } catch (error) {
      debugPrint('[PerfExportService] shareFile 失败（降级 false）: $error');
      return false;
    }
  }

  /// 分享一份报告：优先分享文件；失败（如 docs 目录未被 FileProvider 覆盖）
  /// 退化为分享文本内容。
  Future<bool> shareReport({
    required String path,
    required String content,
    required String mimeType,
    String? title,
  }) async {
    final fileOk =
        await shareFile(path, mimeType: mimeType, subject: title, title: title);
    if (fileOk) return true;
    return shareText(content, subject: title, title: title);
  }
}
