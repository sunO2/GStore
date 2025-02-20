import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/service/user_manager.dart';
import 'state.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

class AuthPageLogic extends GetxController with GithubRequestMix {
  InAppWebViewController? webViewController;

  final loginRequestCancelToken = CancelToken();

  final userManager = Get.find<UserManager>();
  final AuthPageState state = AuthPageState();

  void loadUrl(String url) {
    log("开始加载url $url ${null != webViewController}");
    webViewController?.loadUrl(
        urlRequest: URLRequest(url: WebUri.uri(Uri.parse(url))));
  }

  void registerEvent(InAppWebViewController controller) {
    webViewController = controller;
    controller.addJavaScriptHandler(
        handlerName: "gstore_login_to_github",
        callback: (data) {
          webViewController?.loadUrl(
              urlRequest: URLRequest(
                  url: WebUri.uri(
                      Uri.parse("https://github.com/login/device"))));
        });
  }

  void startVerification(String code, int interval, String? deviceCode) {}

  getDeviceCode() {
    state.status.value = AuthStatus.requestUserCode;
    userManager.deviceId.then((value) async {
      if (value.deviceCode?.isNotEmpty ?? false) {
        state.verificationCode.value = value.userCode ?? "";
        state.status.value = AuthStatus.verifying;
        await webViewController?.evaluateJavascript(
            source:
                "fillUserCode('${state.verificationCode.value.replaceAll("-", "")}')");

        Future.delayed(Duration(seconds: value.interval ?? 5), () {
          userManager
              .startLoginOfTimer(value.deviceCode!, value.interval ?? 5,
                  loginRequestCancelToken)
              .then((value) {
            if (null != value) {
              state.status.value = AuthStatus.success;
              state.verificationCode.value = '';
              loadUrl(value.htmlUrl ?? "");
            }
          });
        });
      }
    }).onError((error, stackTrace) {
      log("获取设备码失败 $error");
      state.status.value = AuthStatus.initial;
    });
  }

  Future<void> copyVerificationCode() async {
    await Clipboard.setData(ClipboardData(text: state.verificationCode.value));
    Get.snackbar('提示', '验证码已复制到剪贴板');
  }

  @override
  void onClose() {
    userManager.cancelLogin();
    loginRequestCancelToken.cancel();
    super.onClose();
  }
}
