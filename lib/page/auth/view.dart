import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:gstore/core/core.dart';
import 'logic.dart';
import 'state.dart';

class AuthPage extends StatelessWidget {
  const AuthPage({super.key});

  @override
  Widget build(BuildContext context) {
    final logic = Get.put(AuthPageLogic());
    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        title: const Text("GitHub 登录",
            style: TextStyle(fontWeight: FontWeight.bold)),
      ),
      body: PopScope(
          canPop: false,
          onPopInvokedWithResult: (didpop, result) async {
            bool isSuccess = logic.state.status.value == AuthStatus.success;
            if (!isSuccess &&
                (await logic.webViewController?.canGoBack() ?? false)) {
              logic.webViewController?.goBack();
              return;
            }
            Get.back(result: logic.state.status.value);
          },
          child: InAppWebView(
            onWebViewCreated: (controller) {
              logic.registerEvent(controller);
            },
            initialUrlRequest: URLRequest(
                url: WebUri.uri(Uri.parse(
                    "file:///android_asset/flutter_assets/assets/auth/auth_des.html"))), // https://github.com/login/device"))),
            onLoadStop: (controller, url) {
              var urlString = url.toString();
              log("当前加载的url: $urlString");
              controller.injectJavascriptFileFromAsset(
                  assetFilePath: "assets/auth/auto_input_auth_code.js");
              if (urlString
                  .endsWith("/login/device?skip_account_picker=true")) {
                logic.state.status.value = AuthStatus.initial;
              } else if (urlString.endsWith("/login/device/success")) {
                logic.state.status.value = AuthStatus.success;
              }
            },
            initialSettings: InAppWebViewSettings(
              isInspectable: false,
              javaScriptEnabled: true,
            ),
          )),
      floatingActionButton: Obx(() {
        if (logic.state.status.value == AuthStatus.initial ||
            logic.state.status.value == AuthStatus.requestUserCode) {
          return FloatingActionButton.extended(
            onPressed: () {
              if (logic.state.status.value != AuthStatus.requestUserCode) {
                logic.getDeviceCode();
              }
            },
            label: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                const Text("获取验证码"),
                const SizedBox(
                  width: 8,
                ),
                if (logic.state.status.value == AuthStatus.requestUserCode)
                  const CupertinoActivityIndicator(
                    radius: 6,
                  ),
              ],
            ),
          );
        } else if (logic.state.status.value == AuthStatus.verifying) {
          return Container(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.end,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surface,
                    borderRadius: BorderRadius.circular(8),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.1),
                        blurRadius: 8,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      InkWell(
                        onTap: logic.copyVerificationCode,
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              '验证码: ${logic.state.verificationCode.value}',
                              style: const TextStyle(fontSize: 12),
                            ),
                            const SizedBox(
                              width: 4,
                            ),
                            const Icon(
                              Icons.copy,
                              size: 10,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        } else {
          return const SizedBox();
        }
      }),
    );
  }
}
