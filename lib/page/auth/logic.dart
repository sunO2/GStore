import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/router/app_router.dart';
import 'state.dart';

/// GitHub 认证页业务逻辑（Riverpod 版）。
class AuthPageNotifier extends Notifier<AuthPageState> {
  /// 登录页 WebView 控制器（仅承载加载/回退等操作，非 UI 数据，不入 state）。
  InAppWebViewController? webViewController;

  /// 登录轮询取消令牌（页面销毁时一并取消，结束轮询）。
  final loginRequestCancelToken = CancelToken();

  final userManager = UserManager.instance;

  /// 页面监听计数（页面打开时 watch 增加，销毁时减少）。
  /// 等价原 GetX `Get.isRegistered`：用于异步回调后判断页面是否仍存活。
  int _listenerCount = 0;

  /// 页面是否仍存活（存在监听者即视为存活）。
  bool get _pageAlive => _listenerCount > 0;

  @override
  AuthPageState build() {
    ref.onAddListener(() => _listenerCount++);
    ref.onRemoveListener(() {
      _listenerCount--;
      // 页面（唯一监听者）关闭 → 等价原 GetX onClose：取消进行中的登录轮询
      if (!_pageAlive) {
        userManager.cancelLogin();
        loginRequestCancelToken.cancel();
      }
    });
    // provider 销毁兜底（app 容器关闭时）
    ref.onDispose(() {
      userManager.cancelLogin();
      loginRequestCancelToken.cancel();
    });
    return const AuthPageState();
  }

  /// 直接写入状态字段（view 在 onLoadStop 等非逻辑回调中调用）。
  void setStatus(AuthStatus status) {
    state = state.copyWith(status: status);
  }

  /// 取消进行中的登录轮询（页面主动关闭/外部取消时调用；ref.onDispose 同样清理）
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
    state = const AuthPageState();

    controller.addJavaScriptHandler(
        handlerName: "gstore_login_to_github",
        callback: (data) {
          webViewController?.loadUrl(
              urlRequest: URLRequest(
                  url: WebUri.uri(
                      Uri.parse("https://github.com/login/device"))));
        });
  }

  void getDeviceCode() {
    state = state.copyWith(status: AuthStatus.requestUserCode);
    userManager.deviceId.then((value) async {
      if (value.deviceCode?.isNotEmpty ?? false) {
        state = state.copyWith(verificationCode: value.userCode ?? "");
        state = state.copyWith(status: AuthStatus.verifying);

        // 自动填充验证码到 GitHub 页面（JS 返回 true/false）；失败降级提示手动输入
        try {
          final filled = await webViewController?.evaluateJavascript(
            source:
                "fillUserCode('${state.verificationCode.replaceAll("-", "")}')",
          );
          if (filled != true && filled != 'true') {
            log('fillUserCode 自动填充失败（页面结构可能已变化）');
            // 页面可能未加载完成/结构不匹配 → 提示手动输入（不阻塞后续轮询）
            if (_pageAlive) {
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
              state = state.copyWith(status: AuthStatus.success);
              state = state.copyWith(verificationCode: '');

              // 检查页面是否还存在，避免在页面销毁后显示提示
              if (_pageAlive) {
                try {
                  AppDialogs.showSuccess('登录成功！欢迎回来，${userInfo.login}',
                      title: '登录成功');
                } catch (e) {
                  log("显示成功提示失败（页面可能已关闭）：$e");
                }
              }

              // 延迟自动返回（GoRouter 无 context pop；success toast 已在上方提示）
              await Future.delayed(const Duration(milliseconds: 800));
              if (_pageAlive) {
                try {
                  appRouter.pop();
                } catch (e) {
                  log("返回失败（页面可能已关闭）：$e");
                }
              }
            } else {
              log("登录失败：userInfo 为 null");
              state = state.copyWith(status: AuthStatus.initial);
              if (_pageAlive) {
                try {
                  AppDialogs.showError('登录失败，请重试', title: '登录失败');
                } catch (e) {
                  log("显示错误提示失败：$e");
                }
              }
            }
          } catch (e) {
            log("登录轮询失败：$e");
            state = state.copyWith(status: AuthStatus.initial);
            // 错误信息已在 UserManager 中显示，这里不需要再显示
          }
        });
      } else {
        // deviceCode 为空，说明获取失败，重置状态
        log("获取设备码失败：返回的 deviceCode 为空");
        state = state.copyWith(status: AuthStatus.initial);
      }
    }).onError((error, stackTrace) {
      log("获取设备码失败 $error");
      state = state.copyWith(status: AuthStatus.initial);
    });
  }

  Future<void> copyVerificationCode() async {
    await Clipboard.setData(ClipboardData(text: state.verificationCode));
    AppDialogs.showSuccess('验证码已复制到剪贴板', title: '提示');
  }
}

/// 认证页 provider。
final authPageProvider =
    NotifierProvider<AuthPageNotifier, AuthPageState>(AuthPageNotifier.new);