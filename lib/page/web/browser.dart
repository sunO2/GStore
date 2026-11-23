import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:gstore/core/core.dart';

/// GStore 浏览器封装——以 app 内嵌方式打开外部链接
/// （Android：Chrome Custom Tabs；iOS：Safari View Controller）。
class GStoreInAppBrowser {
  final AppSummary? appInfo;
  GStoreInAppBrowser({this.appInfo});

  /// 打开 URL（app 内嵌浏览，不离开应用）。
  Future<void> open({
    required WebUri url,
    ChromeSafariBrowserSettings? settings,
  }) async {
    try {
      await ChromeSafariBrowser().open(url: url, settings: settings);
    } catch (e) {
      appLog.error('GStoreInAppBrowser: 打开浏览器失败 - $e');
    }
  }
}
