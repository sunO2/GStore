import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 状态栏图标亮度：反相主题亮度（透明状态栏上亮主题用深色图标，反之亦然）。
Brightness statusBarBrightnessOf(Brightness themeBrightness) {
  if (themeBrightness == Brightness.dark) {
    return Brightness.light;
  } else {
    return Brightness.dark;
  }
}

configStatusBar(BuildContext context) {
  final statusBarBrightness = statusBarBrightnessOf(Theme.of(context).brightness);
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