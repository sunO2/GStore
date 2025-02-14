import 'package:gstore/core/core.dart';
import 'package:gstore/db/apps/AppInfo.dart';

class ApplistState {
  List<AppInfo> apps = [];
  String version = "";
  final RxInt loginStatus = (-1).obs;

  ApplistState() {
    ///Initialize variables
  }
}
