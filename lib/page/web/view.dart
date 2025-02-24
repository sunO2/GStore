import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:get/get.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/theme/theme_utils.dart';
import 'package:gstore/main.dart';
import 'logic.dart';

class WebPage extends StatelessWidget {
  const WebPage({super.key});

  @override
  Widget build(BuildContext context) {
    final logic = Get.put(WebPageLogic());
    return Scaffold(
      appBar: PreferredSize(
          preferredSize: const Size(0, 56),
          child: Obx(() => AppBar(
                backgroundColor: logic.state.appBarColor.value,
                foregroundColor: logic.state.appBarColor.value.isDark
                    ? Colors.white
                    : Colors.black,
                title: Text(logic.appInfo?.name ?? ""),
              ))),
      body: RefreshIndicator(
          child: PopScope(
              canPop: false,
              onPopInvokedWithResult: (didpop, result) async {
                if (await logic.webViewController?.canGoBack() ?? false) {
                  logic.webViewController?.goBack();
                  return;
                }
                if (!didpop) Get.back();
              },
              child: InAppWebView(
                onWebViewCreated: (controller) {
                  logic.registerEvent(controller);
                },
                onDownloadStart: (controller, url) {
                  log("开始下载：$url");
                },
                onDownloadStartRequest: (controller, downloadStartRequest) {
                  log("开始下载：${downloadStartRequest.url}");
                },
                onLoadStop: logic.onLoadStop,
                initialUrlRequest:
                    URLRequest(url: WebUri.uri(Uri.parse(logic.rootUrl))),
                initialSettings: InAppWebViewSettings(
                  javaScriptEnabled: true,
                ),
              )),
          onRefresh: () {
            return Future.delayed(const Duration(seconds: 2));
          }),
      // body: WebViewWidget(controller: logic.controller),
      floatingActionButton: FloatingActionButton(
        onPressed: () => Get.back(),
        child: const Icon(Icons.close),
      ),
    );
  }
}
