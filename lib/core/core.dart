import 'package:get/get.dart';
import 'package:gstore/db/apps/AppInfo.dart';

export 'package:gstore/core/utils/logger.dart';
export 'package:gstore/core/routers.dart';
export 'package:get/get.dart';
export 'package:gstore/http/github_request_mix.dart';
export 'package:gstore/db/apps/AppInfo.dart';
export 'dart:async';
export 'dart:convert';

void updateConfig(AppInfoConfig? config) {
  if (null != config) {
    Get.put(config, tag: "config");
  }
}

AppInfoConfig? getConfig() {
  try {
    AppInfoConfig? config = Get.find(tag: "config");
    return config;
  } catch (e) {
    return null;
  }
}

String getProxy() {
  AppInfoConfig? config = getConfig();
  if (null == config) {
    return "https://ghgo.xyz/";
  }
  return config.proxy!;
}
