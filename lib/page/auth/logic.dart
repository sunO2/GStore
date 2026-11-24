import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/router/app_router.dart';
import 'package:gstore/core/service/login_notification_service.dart';
import 'package:gstore/http/github/user_info/user_info.dart';
import 'package:gstore/page/web/browser.dart';
import 'state.dart';

/// GitHub 设备登录页面（系统浏览器打开；用户在此输入验证码）。
const String _githubDeviceLoginUrl = 'https://github.com/login/device';

/// GitHub 认证页业务逻辑（Riverpod 版）。
class AuthPageNotifier extends Notifier<AuthPageState> {
  /// 登录轮询取消令牌（页面销毁或重新获取时一并取消，结束轮询）。
  CancelToken loginRequestCancelToken = CancelToken();

  final userManager = UserManager.instance;

  /// 页面监听计数（页面打开时 watch 增加，销毁时减少）。
  int _listenerCount = 0;

  /// 页面是否仍存活（存在监听者即视为存活）。
  bool get _pageAlive => _listenerCount > 0;

  @override
  AuthPageState build() {
    ref.onAddListener(() => _listenerCount++);
    ref.onRemoveListener(() {
      _listenerCount--;
      // 页面（唯一监听者）关闭 → 结束进行中的登录轮询并移除登录通知
      if (!_pageAlive) {
        userManager.cancelLogin();
        loginRequestCancelToken.cancel();
        LoginNotificationService.instance.cancel();
      }
    });
    // provider 销毁兜底（app 容器关闭时）
    ref.onDispose(() {
      userManager.cancelLogin();
      loginRequestCancelToken.cancel();
      LoginNotificationService.instance.cancel();
    });
    // 订阅轮询日志，登录说明页展示轮询进度，并同步到通知栏
    userManager.pollLogStream.listen(_appendLog);
    return const AuthPageState();
  }

  /// 追加一条轮询日志（保留最近 50 条），供页面日志面板展示。
  void _appendLog(String log) {
    var logs = List<String>.of(state.pollingLogs)..add(log);
    if (logs.length > 50) logs = logs.sublist(logs.length - 50);
    state = state.copyWith(pollingLogs: logs);
  }

  /// 进入登录说明页时重置状态（避免再次进入页面时显示上一次的验证码/日志）。
  void reset() {
    state = const AuthPageState();
  }

  /// 切换轮询日志折叠状态（登录说明页用于展示进度）。
  void togglePollLogs() {
    state = state.copyWith(showPollLogs: !state.showPollLogs);
  }

  /// 取消进行中的登录轮询（页面主动关闭/重新获取时调用）。
  void cancelLogin() {
    userManager.cancelLogin();
    LoginNotificationService.instance.cancel();
    if (!loginRequestCancelToken.isCancelled) {
      loginRequestCancelToken.cancel();
    }
  }

  /// 后台回到前台（如从 GitHub 浏览器返回）：
  /// - 已有请求在途 → 沿用当前链，等它返回后立即补发一次（不另起链）；
  /// - 定时器仍在等待且已超过一个轮询间隔 → 立即补发一次；
  /// - 轮询链已停（如后台期间网络失败）→ 重建轮询链（超期时立即发起）。
  Future<void> onAppResumed() async {
    if (state.status != AuthStatus.verifying &&
        state.status != AuthStatus.initial) {
      return;
    }
    if (!userManager.canResumePolling) return;
    // 请求在途（常见于后台期间发出的那次）：只登记「返回后立即补发」，
    // 绝不能另起一条链——否则同一设备码会被并发轮询，先到的成功结果还会
    // 因为令牌换代被丢弃，表现为「成功了却要再轮询一次才显示登录」。
    if (userManager.resumeAfterPendingRequest()) {
      _appendLog('检测到回到应用，等待在途的登录检查结果…');
      return;
    }
    // 定时器仍在等待：仅有超期时才立即补发，其余情况按原定时间继续。
    if (userManager.isPolling) {
      if (userManager.isPollOverdue && userManager.pollNow()) {
        _appendLog('检测到回到应用且已超过轮询间隔，立即检查登录状态…');
      }
      return;
    }
    // 轮询链已停：换新令牌重建链，旧链结果不再影响页面状态。
    if (!loginRequestCancelToken.isCancelled) {
      loginRequestCancelToken.cancel();
    }
    final token = loginRequestCancelToken = CancelToken();
    if (state.verificationCode.isNotEmpty) {
      state = state.copyWith(status: AuthStatus.verifying);
    }
    _appendLog('检测到回到应用，自动恢复登录轮询…');
    await _handleLoginResult(userManager.resumePolling(token), token);
  }

  /// 手动认证（轮询失败后）：取消当前轮询并用已存设备码重新开始，立即发起一次。
  Future<void> retryPolling() async {
    userManager.cancelLogin();
    loginRequestCancelToken = CancelToken();
    _appendLog('手动重新开始轮询登录状态…');
    if (state.verificationCode.isNotEmpty) {
      state = state.copyWith(status: AuthStatus.verifying);
    }
    final token = loginRequestCancelToken;
    await _handleLoginResult(
      userManager.resumePolling(token, immediate: true),
      token,
    );
  }

  /// 统一处理一次登录轮询结果：成功 → 提示并自动退出；失败 → 进入可手动认证状态。
  ///
  /// [token] 用于识别该次轮询是否已被更新的请求（重新获取/手动认证）取代，
  /// 避免旧请求的结果覆盖新状态或重复关闭页面。
  Future<void> _handleLoginResult(
    Future<UserInfo?> polling,
    CancelToken token,
  ) async {
    try {
      final userInfo = await polling;
      if (!identical(token, loginRequestCancelToken)) return;
      if (userInfo == null) {
        log("登录失败：userInfo 为 null");
        state = state.copyWith(status: AuthStatus.initial);
        return;
      }

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

      // 延迟自动返回
      await Future.delayed(const Duration(milliseconds: 800));
      if (_pageAlive && identical(token, loginRequestCancelToken)) {
        try {
          appRouter.pop(AuthStatus.success);
        } catch (e) {
          log("返回失败（页面可能已关闭）：$e");
        }
      }
    } catch (e) {
      if (!identical(token, loginRequestCancelToken)) return;
      log("登录轮询失败：$e");
      state = state.copyWith(status: AuthStatus.initial);
    }
  }

  /// 进入登录说明页即请求设备码（UserManager.deviceId 会同步把用户码写入剪贴板）。
  Future<void> getDeviceCode() async {
    // 若令牌已被取消（如页面重新进入），换一个新令牌
    if (loginRequestCancelToken.isCancelled) {
      loginRequestCancelToken = CancelToken();
    }
    state = state.copyWith(status: AuthStatus.requestUserCode);
    _appendLog('正在请求 GitHub 设备验证码…');
    userManager.deviceId.then((value) async {
      if (value.deviceCode?.isNotEmpty ?? false) {
        state = state.copyWith(verificationCode: value.userCode ?? '');
        state = state.copyWith(status: AuthStatus.verifying);
        // 验证码有效期（用于页面小字提醒）
        if (value.expiresIn != null) {
          state = state.copyWith(
              codeExpiresAt: DateTime.now()
                  .add(Duration(seconds: value.expiresIn!)));
        }
        // 验证码也写入轮询日志，让日志面板一开始就有内容
        _appendLog(
            '已获取验证码：${value.userCode ?? ''}'
            '${value.expiresIn != null ? '（${value.expiresIn! ~/ 60} 分钟内有效）' : ''}');
        _appendLog('已开始轮询登录状态，在 GitHub 授权成功后即可关闭本页面');

        // 前台通知：请求通知权限，再把验证码写入通知栏；启动前台服务（保持进程存活）
        await LoginNotificationService.instance.requestPermission();
        LoginNotificationService.instance.showLoginNotification(
            value.userCode ?? '',
            expiresIn: value.expiresIn,
            onLog: _appendLog);
        LoginNotificationService.instance.startForegroundService();

        // 开始轮询登录状态（结果统一交给 _handleLoginResult 处理）。
        // 首次请求由轮询链按 GitHub 返回的 interval 等待后自动发出——这里不再
        // 额外 Future.delayed，否则首次请求会多等一个间隔。
        final token = loginRequestCancelToken;
        await _handleLoginResult(
          userManager.startLoginOfTimer(
              value.deviceCode!, value.interval ?? 5, token,
              expiresIn: value.expiresIn),
          token,
        );
      } else {
        log("获取设备码失败：返回的 deviceCode 为空");
        _appendLog('获取设备码失败：deviceCode 为空');
        state = state.copyWith(status: AuthStatus.initial);
      }
    }).onError((error, stackTrace) {
      log("获取设备码失败 $error");
      _appendLog('获取设备码失败：$error');
      state = state.copyWith(status: AuthStatus.initial);
    });
  }

  /// 重新获取设备码：先取消在途轮询，再重新请求。
  void reFetchDeviceCode() {
    cancelLogin();
    getDeviceCode();
  }

  /// 复制验证码到剪贴板。
  Future<void> copyVerificationCode() async {
    await Clipboard.setData(ClipboardData(text: state.verificationCode));
    AppDialogs.showSuccess('验证码已复制到剪贴板', title: '提示');
  }

  /// 去 GitHub 设备登录页（系统浏览器）。
  Future<void> openGitHubDevicePage() =>
      GStoreInAppBrowser().open(url: WebUri(_githubDeviceLoginUrl));
}

/// 认证页 provider。
final authPageProvider =
    NotifierProvider<AuthPageNotifier, AuthPageState>(AuthPageNotifier.new);
