import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/design/design_tokens.dart';
import 'logic.dart';
import 'state.dart';

/// GitHub 认证页
class AuthPage extends ConsumerStatefulWidget {
  const AuthPage({super.key});

  @override
  ConsumerState<AuthPage> createState() => _AuthPageState();
}

class _AuthPageState extends ConsumerState<AuthPage> {
  /// 页面逻辑（build 时从 ref 取，供各构建子方法使用）
  AuthPageNotifier get logic => ref.read(authPageProvider.notifier);

  /// 页面状态（ref.watch，状态变化触发 build 重建）
  AuthPageState get state => ref.watch(authPageProvider);

  @override
  Widget build(BuildContext context) {
    final state = this.state;
    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        title: const Text("GitHub 登录",
            style: TextStyle(fontWeight: FontWeight.bold)),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () async {
            final currentStatus = state.status;

            // 登录成功，直接返回 success
            if (currentStatus == AuthStatus.success) {
              Navigator.of(context).pop(AuthStatus.success);
              return;
            }

            // 正在验证中：验证码已拿到但 token 尚未确认——此时关闭不应判登录成功，
            // 取消防抖轮询后普通返回（不携带 result，调用方不会弹"登录成功"）
            if (currentStatus == AuthStatus.verifying) {
              logic.cancelLogin();
              Navigator.of(context).pop();
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
              Navigator.of(context).pop();
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
            logic.setStatus(AuthStatus.initial);
          }
          // 注意：登录成功判断已改为使用 API 轮询结果（logic.dart），
          // 不再依赖页面 URL 跳转到 /login/device/success
        },
        initialSettings: InAppWebViewSettings(
          isInspectable: false,
          javaScriptEnabled: true,
        ),
      ),
      floatingActionButton: _buildFab(context, state),
    );
  }

  /// 底部 FAB（获取验证码 / 复制验证码；依赖外层 [state] watch 响应式重建）。
  Widget _buildFab(BuildContext context, AuthPageState state) {
    if (state.status == AuthStatus.initial ||
        state.status == AuthStatus.requestUserCode) {
      return FloatingActionButton.extended(
        backgroundColor: Theme.of(context).colorScheme.primaryContainer,
        onPressed: () {
          if (state.status != AuthStatus.requestUserCode) {
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
            if (state.status == AuthStatus.requestUserCode)
              const CupertinoActivityIndicator(
                radius: 6,
              ),
          ],
        ),
      );
    } else if (state.status == AuthStatus.verifying) {
      return FloatingActionButton.extended(
        onPressed: logic.copyVerificationCode,
        label: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '验证码: ${state.verificationCode}',
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
  }
}