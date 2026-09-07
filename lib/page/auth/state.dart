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
  });

  /// GitHub 设备流程用户码。
  final String verificationCode;

  /// 当前认证状态。
  final AuthStatus status;

  AuthPageState copyWith({
    String? verificationCode,
    AuthStatus? status,
  }) {
    return AuthPageState(
      verificationCode: verificationCode ?? this.verificationCode,
      status: status ?? this.status,
    );
  }
}