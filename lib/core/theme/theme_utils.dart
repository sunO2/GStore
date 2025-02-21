import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gstore/core/core.dart';

get statusBarBrightness {
  if (Get.theme.brightness == Brightness.dark) {
    return Brightness.light;
  } else {
    return Brightness.dark;
  }
}

configStatusBar() {
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle(
    statusBarColor: Colors.transparent, // 将状态栏颜色设置为透明
    statusBarBrightness: statusBarBrightness,
    statusBarIconBrightness: statusBarBrightness,
    systemStatusBarContrastEnforced: false,
    systemNavigationBarContrastEnforced: true,
    systemNavigationBarColor: Colors.transparent,
  ));
}
