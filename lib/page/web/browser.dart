import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/db/apps/AppInfo.dart';

class GStoreInAppBrowser extends InAppBrowser {
  final AppInfo appInfo;
  GStoreInAppBrowser(this.appInfo) : super();

  @override
  void onDownloadStartRequest(DownloadStartRequest downloadStartRequest) {
    log("准备下载 $downloadStartRequest");
    super.onDownloadStartRequest(downloadStartRequest);
  }

  @override
  void onDownloadStart(Uri url) {
    log("准备下载 $url");
    super.onDownloadStart(url);
  }
}
