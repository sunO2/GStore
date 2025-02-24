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

extension HexColor on String {
  get fromHex {
    String hex = replaceAll('#', '');
    if (hex.length == 6) {
      hex = 'FF$hex'; // 默认透明度为1（FF）
    } else if (hex.length == 3) {
      hex = 'FF${hex[0]}${hex[0]}${hex[1]}${hex[1]}${hex[2]}${hex[2]}'; // 简写形式
    }
    return Color(int.parse(hex, radix: 16));
  }
}

extension ColorExtension on Color {
  /// Determines if the color is considered light.
  bool isLight() {
    // Calculate the perceived brightness of the color
    double luminance = computeLuminance();
    // Adjust the threshold as needed.  0.5 is a common value.
    return luminance > 0.5;
  }

  /// Determines if the color is considered dark.
  bool get isDark => !isLight();
}
