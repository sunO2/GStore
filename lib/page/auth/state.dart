/// 认证状态枚举
enum AuthStatus {
  /// 空状态
  empty,
  /// 初始状态
  initial,
  /// 请求用户码中
  requestUserCode,
  /// 验证中
  verifying,
  /// 验证成功
  success,
}

/// 认证页状态（不可变）。
class AuthPageState {
  const AuthPageState({
    this.verificationCode = '',
    this.status = AuthStatus.empty,
    List<String>? pollingLogs,
    this.showPollLogs = false,
    this.codeExpiresAt,
  }) : pollingLogs = pollingLogs ?? const [];

  /// GitHub 设备流程用户码。
  final String verificationCode;

  /// 当前认证状态。
  final AuthStatus status;

  /// 轮询日志（登录说明页用于展示轮询进度）。
  final List<String> pollingLogs;

  /// 轮询日志折叠展开状态。
  final bool showPollLogs;

  /// 验证码有效期截止时间（GitHub 设备码 expires_in 推算，用于页面小字提醒）。
  final DateTime? codeExpiresAt;

  AuthPageState copyWith({
    String? verificationCode,
    AuthStatus? status,
    List<String>? pollingLogs,
    bool? showPollLogs,
    DateTime? codeExpiresAt,
  }) {
    return AuthPageState(
      verificationCode: verificationCode ?? this.verificationCode,
      status: status ?? this.status,
      pollingLogs: pollingLogs ?? this.pollingLogs,
      showPollLogs: showPollLogs ?? this.showPollLogs,
      codeExpiresAt: codeExpiresAt ?? this.codeExpiresAt,
    );
  }
}
