import 'package:gstore/core/core.dart';
import 'package:gstore/http/github/dio_client.dart';
import 'package:gstore/http/github/github_auth_api.dart';
import 'state.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'dart:async';
import 'package:flutter/services.dart';

class AuthPageLogic extends GetxController with GithubRequestMix {
  Timer? _timer;
  Timer? _loginRequestTimer;
  InAppWebViewController? webViewController;

  final authApi = Get.find<GithubAuthApi>();
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

  void startVerification(String code, int interval, String? deviceCode) {
    state.verificationCode.value = code;
    state.status.value = AuthStatus.verifying;
  }

  void cancelVerification() {
    _timer?.cancel();
    state.status.value = AuthStatus.empty;
    state.verificationCode.value = '';
  }

  Future<void> copyVerificationCode({String? verificationCode}) async {
    await Clipboard.setData(ClipboardData(text: state.verificationCode.value));
    Get.snackbar('提示', '验证码已复制到剪贴板');
    var call = await webViewController?.evaluateJavascript(
        source:
            "fillUserCode('${state.verificationCode.value.replaceAll("-", "")}')");
  }

  getDeviceCode() {
    state.status.value = AuthStatus.requestUserCode;
    authApi.device("Ov23liK4Xz0eBlefQJJm").then((value) async {
      startVerification(
          value.userCode ?? "", value.interval ?? 5, value.deviceCode);
      if (value.deviceCode?.isNotEmpty ?? false) {
        startTimeRequestAccessToken(value.deviceCode!, value.interval ?? 0);
        copyVerificationCode(verificationCode: value.userCode);
      }
    }).onError((error, stackTrace) {
      log("获取设备码失败 $error");
      state.status.value = AuthStatus.initial;
    });
  }

  startTimeRequestAccessToken(String deviceCode, int interval) {
    if (_loginRequestTimer?.isActive ?? false) _loginRequestTimer?.cancel();
    _loginRequestTimer = Timer.periodic(Duration(seconds: interval), (timer) {
      loginDevice(deviceCode);
    });
  }

  loginDevice(String deviceCode) {
    authApi.login("Ov23liK4Xz0eBlefQJJm", deviceCode).then((value) {
      if (value.error != null && value.interval != null) {
        startTimeRequestAccessToken(deviceCode, value.interval!);
        return;
      }
      if (value.accessToken?.isNotEmpty ?? false) {
        if (_loginRequestTimer?.isActive ?? false) _loginRequestTimer?.cancel();
        cancelVerification();
        DioClient.instance.setAuthorization(value.accessToken);
      }
      // cancelVerification();
    });
  }

  @override
  void onClose() {
    _timer?.cancel();
    _loginRequestTimer?.cancel();
    super.onClose();
  }
}
