import 'package:gstore/core/core.dart';
import 'package:gstore/http/github/github_auth_api.dart';
import 'state.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'dart:async';
import 'package:flutter/services.dart';

class AuthPageLogic extends GetxController with GithubRequestMix {
  Timer? _timer;
  InAppWebViewController? webViewController;

  void loadUrl(String url) {
    log("开始加载url $url ${null != webViewController}");
    webViewController?.loadUrl(
        urlRequest: URLRequest(url: WebUri.uri(Uri.parse(url))));
  }

  final authApi = Get.find<GithubAuthApi>();
  final AuthPageState state = AuthPageState();

  void startVerification(String code, int interval, String? deviceCode) {
    state.verificationCode.value = code;
    state.status.value = AuthStatus.verifying;
    startTimer(interval, deviceCode);
  }

  void startTimer(int interval, String? deviceCode) {
    state.remainingSeconds.value = 900; // 重置为15分钟
    _timer?.cancel();
    _timer = Timer.periodic(Duration(seconds: interval), (timer) {
      if (state.remainingSeconds.value > 0) {
        state.remainingSeconds.value--;
        loginDevice(deviceCode ?? "");
      } else {
        cancelVerification();
      }
    });
  }

  void cancelVerification() {
    _timer?.cancel();
    state.status.value = AuthStatus.initial;
    state.verificationCode.value = '';
  }

  Future<void> copyVerificationCode() async {
    await Clipboard.setData(ClipboardData(text: state.verificationCode.value));
    Get.snackbar('提示', '验证码已复制到剪贴板');
  }

  @override
  void onReady() {
    super.onReady();
  }

  @override
  void onClose() {
    _timer?.cancel();
    super.onClose();
  }

  getDeviceCode() {
    authApi.device("Ov23liK4Xz0eBlefQJJm").then((value) {
      startVerification(
          value.userCode ?? "", value.interval ?? 5, value.deviceCode);
      loadUrl(value.verificationUri ?? "");
    });
  }

  loginDevice(String deviceCode) {
    authApi.login("Ov23liK4Xz0eBlefQJJm", deviceCode).then((value) {
      log("登录状态更新：${value.toJson()}");
      // cancelVerification();
    });
  }
}
