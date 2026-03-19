import 'package:get/get.dart';

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

class AuthPageState {
  final RxString verificationCode = ''.obs;
  final Rx<AuthStatus> status = AuthStatus.empty.obs;
  AuthPageState() {
    ///Initialize variables
  }
}
