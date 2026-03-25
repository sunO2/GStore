import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/design/design_tokens.dart';
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
    // 重置状态，确保每次打开登录页面都是干净的状态
    state.status.value = AuthStatus.empty;
    state.verificationCode.value = '';

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

        // 开始轮询登录状态
        Future.delayed(Duration(seconds: value.interval ?? 5), () async {
          try {
            final userInfo = await userManager.startLoginOfTimer(
                value.deviceCode!, value.interval ?? 5, loginRequestCancelToken);

            // 以 API 轮询结果为准，不依赖页面 URL
            if (userInfo != null) {
              log("登录成功：${userInfo.login}");
              state.status.value = AuthStatus.success;
              state.verificationCode.value = '';

              // 检查页面是否还存在，避免在页面销毁后显示提示
              if (Get.isRegistered<AuthPageLogic>() && navigator != null) {
                try {
                  AppDialogs.showSuccess('登录成功！欢迎回来，${userInfo.login}',
                      title: '登录成功');
                } catch (e) {
                  log("显示成功提示失败（页面可能已关闭）：$e");
                }
              }

              // 延迟自动返回
              await Future.delayed(const Duration(milliseconds: 800));
              if (Get.isRegistered<AuthPageLogic>()) {
                try {
                  Get.back(result: AuthStatus.success);
                } catch (e) {
                  log("返回失败（页面可能已关闭）：$e");
                }
              }
            } else {
              log("登录失败：userInfo 为 null");
              state.status.value = AuthStatus.initial;
              if (Get.isRegistered<AuthPageLogic>()) {
                try {
                  AppDialogs.showError('登录失败，请重试', title: '登录失败');
                } catch (e) {
                  log("显示错误提示失败：$e");
                }
              }
            }
          } catch (e) {
            log("登录轮询失败：$e");
            state.status.value = AuthStatus.initial;
            // 错误信息已在 UserManager 中显示，这里不需要再显示
          }
        });
      } else {
        // deviceCode 为空，说明获取失败，重置状态
        log("获取设备码失败：返回的 deviceCode 为空");
        state.status.value = AuthStatus.initial;
      }
    }).onError((error, stackTrace) {
      log("获取设备码失败 $error");
      state.status.value = AuthStatus.initial;
    });
  }

  Future<void> copyVerificationCode() async {
    await Clipboard.setData(ClipboardData(text: state.verificationCode.value));
    AppDialogs.showSuccess('验证码已复制到剪贴板', title: '提示');
  }

  @override
  void onClose() {
    userManager.cancelLogin();
    loginRequestCancelToken.cancel();
    super.onClose();
  }
}
