import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/design/design_tokens.dart';
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
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () async {
            final currentStatus = logic.state.status.value;

            // 登录成功或正在验证中，直接返回
            if (currentStatus == AuthStatus.success ||
                currentStatus == AuthStatus.verifying) {
              Get.back(result: AuthStatus.success);
              return;
            }

            // 正在获取验证码，不允许关闭
            if (currentStatus == AuthStatus.requestUserCode) {
              AppDialogs.showWarning('正在获取验证码，请稍候...',
                  title: '提示');
              return;
            }

            // 检查 WebView 是否可以返回
            if (await logic.webViewController?.canGoBack() ?? false) {
              logic.webViewController?.goBack();
              return;
            }

            // 显示确认对话框
            final shouldPop = await AppDialogs.showConfirmDialog(
              title: '确认退出登录？',
              message: '您尚未完成 GitHub 登录，确定要退出吗？',
              confirmText: '确认退出',
              cancelText: '继续登录',
            );

            if (shouldPop == true) {
              Get.back();
            }
          },
        ),
      ),
      body: InAppWebView(
        onWebViewCreated: (controller) {
          logic.registerEvent(controller);
        },
        initialUrlRequest: URLRequest(
            url: WebUri.uri(Uri.parse(
                "file:///android_asset/flutter_assets/assets/auth/auth_des.html"))),
        onLoadStop: (controller, url) {
          var urlString = url.toString();
          debugPrint("当前加载的url: $urlString");
          controller.injectJavascriptFileFromAsset(
              assetFilePath: "assets/auth/auto_input_auth_code.js");
          // 检测是否到达设备登录页面
          if (urlString
              .endsWith("/login/device?skip_account_picker=true")) {
            logic.state.status.value = AuthStatus.initial;
          }
          // 注意：登录成功判断已改为使用 API 轮询结果（logic.dart），
          // 不再依赖页面 URL 跳转到 /login/device/success
        },
        initialSettings: InAppWebViewSettings(
          isInspectable: false,
          javaScriptEnabled: true,
        ),
      ),
      floatingActionButton: Obx(() {
        if (logic.state.status.value == AuthStatus.initial ||
            logic.state.status.value == AuthStatus.requestUserCode) {
          return FloatingActionButton.extended(
            backgroundColor: Theme.of(context).colorScheme.primaryContainer,
            onPressed: () {
              if (logic.state.status.value != AuthStatus.requestUserCode) {
                logic.getDeviceCode();
              }
            },
            label: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Text(
                  "获取验证码",
                  style: Theme.of(context)
                      .textTheme
                      .displaySmall
                      ?.copyWith(fontSize: 14, fontWeight: FontWeight.bold),
                ),
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
          return FloatingActionButton.extended(
            onPressed: logic.copyVerificationCode,
            label: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '验证码: ${logic.state.verificationCode.value}',
                  style: Theme.of(context)
                      .textTheme
                      .displaySmall
                      ?.copyWith(fontSize: 12, fontWeight: FontWeight.bold),
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
          );
        } else {
          return const SizedBox();
        }
      }),
    );
  }
}
