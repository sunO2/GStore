import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/db/apps/AppInfo.dart';

class GStoreInAppBrowser extends ChromeSafariBrowser {
  final AppInfo? appInfo;
  GStoreInAppBrowser({this.appInfo}) : super();
}
