import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/theme/theme_utils.dart';

// import 'package:webview_flutter/webview_flutter.dart';
import 'state.dart';

class WebPageLogic extends GetxController with GithubRequestMix {
  final WebPageState state = WebPageState();
  InAppWebViewController? webViewController;
  final String rootUrl = Get.arguments["url"];
  final AppInfo? appInfo = Get.arguments["appInfo"];

  onLoadStop(InAppWebViewController ctroller, url) async {
    var color = await ctroller.evaluateJavascript(source: '''(function() {
        let themeColorMeta = document.querySelector('meta[name="theme-color"]');
        if (themeColorMeta) {
          return themeColorMeta.getAttribute('content');
        }
        let themeColorCSS = getComputedStyle(document.documentElement).getPropertyValue('--theme-color');
        if (themeColorCSS) {
          return themeColorCSS.trim();
        }
        return null;
      })()''');
    log("输出颜色: $color");
    state.appBarColor.value = (color as String).fromHex;

    // Determine if the appBarColor is dark or light and set the appBarContentColor accordingly
    // if (color != null) {
    //   Color appBarColor = Color(int.parse(color.replaceAll('#', '0xFF')));
    //   if (appBarColor.isDark()) {
    //     state.appBarContentColor.value = Colors.white;
    //   } else {
    //     state.appBarContentColor.value = Colors.black;
    //   }
    // }
  }

  void registerEvent(InAppWebViewController controller) {
    webViewController = controller;
  }
}
