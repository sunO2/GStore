import 'package:get/get.dart';
import 'package:gstore/http/github/github_client.dart';
import 'package:installed_apps/app_info.dart';

class DetailState {
  var body = "".obs;
  List<dynamic> release = <dynamic>[].obs;
  var sourceUrl = "";
  var apiInfo = const ApiList().obs;
  AppInfo? installInfo;

  DetailState() {
    ///Initialize variables
  }
}
