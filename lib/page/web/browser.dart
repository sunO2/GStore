import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/db/apps/AppInfo.dart';

/// GStore 浏览器封装
/// 使用系统默认浏览器打开（避免 Chrome Custom Tabs 在部分 ROM 上闪退）
class GStoreInAppBrowser {
  final AppInfo? appInfo;
  GStoreInAppBrowser({this.appInfo});

  /// 打开 URL（用系统默认浏览器，兼容性最好）
  Future<void> open({
    required WebUri url,
    ChromeSafariBrowserSettings? settings,
  }) async {
    try {
      await InAppBrowser.openWithSystemBrowser(url: url);
    } catch (e) {
      debugPrint('GStoreInAppBrowser: 打开系统浏览器失败 - $e');
      // 兜底：尝试用 url_launcher 或直接忽略
    }
  }
}
