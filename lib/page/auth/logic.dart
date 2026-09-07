import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/design/design_tokens.dart';
import 'package:gstore/core/router/app_router.dart';
import 'package:gstore/core/service/user_manager.dart';
import 'state.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

class AuthPageLogic extends GetxController with GithubRequestMix {
  InAppWebViewController? webViewController;

  final loginRequestCancelToken = CancelToken();

  final userManager = UserManager.instance;
  final AuthPageState state = AuthPageState();

  /// 取消进行中的登录轮询（页面主动关闭/外部取消时调用；onClose 同样清理）
  void cancelLogin() {
    userManager.cancelLogin();
    if (!loginRequestCancelToken.isCancelled) {
      loginRequestCancelToken.cancel();
    }
  }

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

  getDeviceCode() {
    state.status.value = AuthStatus.requestUserCode;
    userManager.deviceId.then((value) async {
      if (value.deviceCode?.isNotEmpty ?? false) {
        state.verificationCode.value = value.userCode ?? "";
        state.status.value = AuthStatus.verifying;

        // 自动填充验证码到 GitHub 页面（JS 返回 true/false）；失败降级提示手动输入
        try {
          final filled = await webViewController?.evaluateJavascript(
            source:
                "fillUserCode('${state.verificationCode.value.replaceAll("-", "")}')",
          );
          if (filled != true && filled != 'true') {
            log('fillUserCode 自动填充失败（页面结构可能已变化）');
            // 页面可能未加载完成/结构不匹配 → 提示手动输入（不阻塞后续轮询）
            if (Get.isRegistered<AuthPageLogic>() && navigator != null) {
              try {
                AppDialogs.showWarning('未能自动填入验证码，请在网页中手动输入',
                    title: '验证码');
              } catch (e) {
                log("提示失败：$e");
              }
            }
          }
        } catch (e) {
          log("填充验证码失败：$e");
        }

        // 开始轮询登录状态
        Future.delayed(Duration(seconds: value.interval ?? 5), () async {
          try {
            final userInfo = await userManager.startLoginOfTimer(
                value.deviceCode!, value.interval ?? 5, loginRequestCancelToken,
                expiresIn: value.expiresIn);

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

              // 延迟自动返回（GoRouter 无 context pop；success toast 已在上方提示）
              await Future.delayed(const Duration(milliseconds: 800));
              if (Get.isRegistered<AuthPageLogic>()) {
                try {
                  appRouter.pop();
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
