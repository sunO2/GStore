import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'logic.dart';

class WebPage extends StatelessWidget {
  const WebPage({super.key});

  @override
  Widget build(BuildContext context) {
    final logic = Get.put(WebPageLogic());
    var args = Get.arguments;
    return Scaffold(
      // body: WebViewWidget(controller: logic.controller),
      floatingActionButton: FloatingActionButton(
        onPressed: () => Get.back(),
        child: const Icon(Icons.close),
      ),
    );
  }
}
