import 'package:get/get.dart';
import 'package:gstore/db/apps/AppInfo.dart';

export 'package:gstore/db/db_manager.dart';
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

void updateDataBaseVersion(String? version) {
  AppInfoConfig? config = getConfig();
  updateConfig(AppInfoConfig(version ?? "0.0.0", config?.proxy));
}

void updateProxy(String? proxyUrl) {
  AppInfoConfig? config = getConfig();
  updateConfig(AppInfoConfig(config?.version ?? "0.0.0", proxyUrl));
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
    return "https://ghfast.top/";
  }
  return config.proxy ?? "";
}

String get proxy => getProxy();
